//! BGE-M3 model lifecycle for hybrid search.
//!
//! State machine:
//!   Uninitialized → Loading → Ready
//!                         ↘ Failed{retry_after}
//!                              ↑___ (timer) ___|
//!   Disabled is sticky (sqlite-vec missing, vectors table empty, etc.)
//!
//! Concurrency: first hybrid request transitions Uninitialized → Loading,
//! subsequent in-flight requests block on a Notify; one shared
//! Arc<TextEmbedding> is handed out once Ready. Embedding calls are
//! serialized through a Mutex on the model (ONNX runtime is not thread
//! safe under concurrent embed).

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use fastembed::{EmbeddingModel, InitOptions, TextEmbedding};
use tokio::sync::{Mutex, Notify, RwLock};

#[derive(Debug, Clone)]
pub enum ModelState {
    Uninitialized,
    Loading,
    Ready,
    Failed {
        reason: String,
        retry_after: Duration,
    },
    Disabled(String),
}

#[derive(Clone)]
pub struct ModelHandle {
    inner: Arc<Inner>,
}

struct Inner {
    state: RwLock<RawState>,
    notify: Notify,
    embed_lock: Mutex<()>,
    cache_dir: std::path::PathBuf,
}

enum RawState {
    Uninitialized,
    Loading,
    Ready(Arc<Mutex<TextEmbedding>>),
    Failed {
        at: Instant,
        reason: String,
        retry_after: Duration,
    },
    Disabled(String),
}

const LOAD_TIMEOUT: Duration = Duration::from_secs(30);
const FAILED_BACKOFF: Duration = Duration::from_secs(300);

impl ModelHandle {
    pub fn new() -> Self {
        Self::with_cache_dir(std::env::temp_dir().join("reader-fastembed"))
    }

    pub fn with_cache_dir(cache_dir: std::path::PathBuf) -> Self {
        Self {
            inner: Arc::new(Inner {
                state: RwLock::new(RawState::Uninitialized),
                notify: Notify::new(),
                embed_lock: Mutex::new(()),
                cache_dir,
            }),
        }
    }

    pub async fn snapshot(&self) -> ModelState {
        match &*self.inner.state.read().await {
            RawState::Uninitialized => ModelState::Uninitialized,
            RawState::Loading => ModelState::Loading,
            RawState::Ready(_) => ModelState::Ready,
            RawState::Failed {
                reason,
                retry_after,
                ..
            } => ModelState::Failed {
                reason: reason.clone(),
                retry_after: *retry_after,
            },
            RawState::Disabled(r) => ModelState::Disabled(r.clone()),
        }
    }

    pub async fn disable(&self, reason: impl Into<String>) {
        let mut s = self.inner.state.write().await;
        *s = RawState::Disabled(reason.into());
        self.inner.notify.notify_waiters();
    }

    /// Test-only hook: simulate a failed state without doing any work.
    pub async fn force_failed(&self, reason: impl Into<String>, retry_after: Duration) {
        let mut s = self.inner.state.write().await;
        *s = RawState::Failed {
            at: Instant::now(),
            reason: reason.into(),
            retry_after,
        };
    }

    /// Test-only hook that drives ensure_loaded's read-only branches without
    /// having to actually load the model.
    pub async fn ensure_loaded_for_test_fail(&self) -> Result<()> {
        let s = self.inner.state.read().await;
        match &*s {
            RawState::Disabled(r) => Err(anyhow!("disabled: {r}")),
            RawState::Failed {
                at,
                retry_after,
                reason,
            } => {
                if at.elapsed() < *retry_after {
                    Err(anyhow!("backoff: {reason}"))
                } else {
                    Err(anyhow!("retry permitted"))
                }
            }
            _ => Err(anyhow!("test stub: not loading")),
        }
    }

    /// Production entry point. Lazy-loads BGE-M3 on first call. Subsequent
    /// callers either reuse the Ready model or wait on the loader.
    pub async fn embed_query(&self, q: &str) -> Result<Vec<f32>> {
        self.ensure_loaded().await?;
        let _guard = self.inner.embed_lock.lock().await;
        let s = self.inner.state.read().await;
        match &*s {
            RawState::Ready(model) => {
                let mut m = model.lock().await;
                let prefixed = format!("query: {q}");
                let mut out = m
                    .embed(vec![prefixed], None)
                    .context("embed query")?;
                Ok(out.swap_remove(0))
            }
            _ => Err(anyhow!("model not ready")),
        }
    }

    async fn ensure_loaded(&self) -> Result<()> {
        loop {
            // Register interest in any upcoming notify BEFORE reading state.
            // If the loader transitions Loading → Ready/Failed between when
            // we observe Loading and when we await, this future will already
            // hold a permit and resolve immediately rather than hanging.
            let notified = self.inner.notify.notified();
            tokio::pin!(notified);

            {
                let s = self.inner.state.read().await;
                match &*s {
                    RawState::Ready(_) => return Ok(()),
                    RawState::Disabled(r) => return Err(anyhow!("disabled: {r}")),
                    RawState::Failed {
                        at,
                        retry_after,
                        reason,
                    } => {
                        if at.elapsed() < *retry_after {
                            return Err(anyhow!("backoff: {reason}"));
                        }
                    }
                    RawState::Loading => {
                        drop(s);
                        notified.as_mut().await;
                        continue;
                    }
                    RawState::Uninitialized => {}
                }
            }

            // Transition Uninitialized | Failed(elapsed) → Loading. Only one
            // task wins this race; the rest fall back into the Loading branch.
            {
                let mut s = self.inner.state.write().await;
                match &*s {
                    RawState::Uninitialized => {}
                    RawState::Failed { at, retry_after, .. } if at.elapsed() >= *retry_after => {}
                    _ => continue,
                }
                *s = RawState::Loading;
            }

            let cache_dir = self.inner.cache_dir.clone();
            let load = tokio::task::spawn_blocking(move || {
                TextEmbedding::try_new(
                    InitOptions::new(EmbeddingModel::BGEM3)
                        .with_show_download_progress(false)
                        .with_cache_dir(cache_dir),
                )
            });
            let timed = tokio::time::timeout(LOAD_TIMEOUT, load).await;

            let outcome = match timed {
                Ok(Ok(Ok(model))) => Ok(model),
                Ok(Ok(Err(e))) => Err(format!("init: {e}")),
                Ok(Err(e)) => Err(format!("task: {e}")),
                Err(_) => Err(format!("timeout after {LOAD_TIMEOUT:?}")),
            };

            let mut s = self.inner.state.write().await;
            let result = match outcome {
                Ok(model) => {
                    *s = RawState::Ready(Arc::new(Mutex::new(model)));
                    Ok(())
                }
                Err(reason) => {
                    *s = RawState::Failed {
                        at: Instant::now(),
                        reason: reason.clone(),
                        retry_after: FAILED_BACKOFF,
                    };
                    Err(anyhow!("model init failed: {reason}"))
                }
            };
            self.inner.notify.notify_waiters();
            return result;
        }
    }
}

impl Default for ModelHandle {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// vec_search: KNN over entry_vectors with filters pushed into the SQL.

use rusqlite::Connection;

const COSINE_FLOOR: f64 = 0.45;
const VEC_OVERFETCH_STAGES: &[usize] = &[30, 60, 120, 240];

#[derive(Debug, Clone)]
pub struct VecHit {
    pub path: String,
    pub cosine: f64,
}

/// Run a vec0 KNN search over a vectors-only DB connection (the entries table
/// lives in a *separate* index DB now). Type/rating/theme filters are applied
/// in Rust via `accept` against the caller's loaded entries, with adaptive
/// over-fetch when the filter strips the initial top-k too aggressively.
/// Returns up to `limit` hits with `cosine >= COSINE_FLOOR`.
pub fn vec_search(
    conn: &Connection,
    qvec: &[f32],
    limit: usize,
    accept: impl Fn(&str) -> bool,
) -> Result<Vec<VecHit>> {
    let qbytes: Vec<u8> = qvec.iter().flat_map(|f| f.to_le_bytes()).collect();
    let mut accumulated: Vec<VecHit> = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for &k in VEC_OVERFETCH_STAGES {
        if accumulated.len() >= limit {
            break;
        }

        let mut stmt = conn.prepare(
            "SELECT path, distance FROM entry_vectors
             WHERE embedding MATCH ? AND k = ?
             ORDER BY distance",
        )?;
        let rows = stmt.query_map(rusqlite::params![qbytes, k as i64], |row| {
            let path: String = row.get(0)?;
            let distance: f64 = row.get(1)?;
            Ok((path, 1.0 - distance))
        })?;

        for r in rows {
            let (path, cosine) = r?;
            if cosine < COSINE_FLOOR {
                continue;
            }
            if !accept(&path) {
                continue;
            }
            if seen.insert(path.clone()) {
                accumulated.push(VecHit { path, cosine });
                if accumulated.len() >= limit {
                    break;
                }
            }
        }
    }

    Ok(accumulated)
}
