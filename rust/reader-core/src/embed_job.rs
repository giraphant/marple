//! Background embedding-build job state.
//!
//! `EmbedJob` is a small, runtime-agnostic state machine that tracks one
//! semantic-vector build: its phase, progress (embedded / total) and outcome.
//! It owns no model and knows nothing about HTTP — the API layer spawns the
//! actual `build_embeddings_with_progress` work on a background task and feeds
//! progress + the final outcome back through this handle.
//!
//! Single-flight is enforced by `try_begin`: only an Idle/Done/Failed job can
//! transition to Running, so a boot auto-start and a concurrent manual trigger
//! can never run two builds at once.

use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc, Mutex,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EmbedPhase {
    Idle,
    Running,
    Done,
    Failed,
}

/// Outcome of the background build task, mapped onto a terminal state by
/// [`EmbedJob::settle`]. `Panicked` exists so a join error / panic in the
/// blocking task still drives the job out of `Running` instead of wedging it.
#[derive(Debug)]
pub enum EmbedOutcome {
    Ok(usize),
    BuildError(String),
    Panicked(String),
}

#[derive(Debug, Clone)]
pub struct EmbedStatus {
    pub phase: EmbedPhase,
    pub embedded: usize,
    pub total: usize,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub error: Option<String>,
}

#[derive(Clone)]
pub struct EmbedJob {
    inner: Arc<Inner>,
}

struct Inner {
    phase: Mutex<PhaseData>,
    embedded: AtomicUsize,
    total: AtomicUsize,
}

struct PhaseData {
    phase: EmbedPhase,
    started_at: Option<String>,
    completed_at: Option<String>,
    error: Option<String>,
}

impl EmbedJob {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Inner {
                phase: Mutex::new(PhaseData {
                    phase: EmbedPhase::Idle,
                    started_at: None,
                    completed_at: None,
                    error: None,
                }),
                embedded: AtomicUsize::new(0),
                total: AtomicUsize::new(0),
            }),
        }
    }

    /// Single-flight gate. Returns `true` and moves to `Running` only from a
    /// non-running state, resetting progress + outcome for the new run. A job
    /// already `Running` returns `false` and is left untouched.
    pub fn try_begin(&self) -> bool {
        let mut p = self.lock();
        if p.phase == EmbedPhase::Running {
            return false;
        }
        p.phase = EmbedPhase::Running;
        p.started_at = Some(now());
        p.completed_at = None;
        p.error = None;
        self.inner.embedded.store(0, Ordering::SeqCst);
        self.inner.total.store(0, Ordering::SeqCst);
        true
    }

    pub fn set_total(&self, n: usize) {
        self.inner.total.store(n, Ordering::SeqCst);
    }

    /// Set the absolute embedded count. The build callback reports cumulative
    /// `(done, total)`, so an absolute setter matches it without delta math.
    pub fn set_embedded(&self, n: usize) {
        self.inner.embedded.store(n, Ordering::SeqCst);
    }

    pub fn finish_ok(&self) {
        let mut p = self.lock();
        p.phase = EmbedPhase::Done;
        p.completed_at = Some(now());
        p.error = None;
    }

    pub fn finish_err(&self, msg: impl Into<String>) {
        let mut p = self.lock();
        p.phase = EmbedPhase::Failed;
        p.error = Some(msg.into());
    }

    /// Map a background-task outcome onto a terminal state. Every variant lands
    /// in `Done` or `Failed`, so a panic can never leave the job `Running`.
    pub fn settle(&self, outcome: EmbedOutcome) {
        match outcome {
            EmbedOutcome::Ok(_) => self.finish_ok(),
            EmbedOutcome::BuildError(msg) => self.finish_err(msg),
            EmbedOutcome::Panicked(msg) => self.finish_err(msg),
        }
    }

    pub fn snapshot(&self) -> EmbedStatus {
        let p = self.lock();
        EmbedStatus {
            phase: p.phase,
            embedded: self.inner.embedded.load(Ordering::SeqCst),
            total: self.inner.total.load(Ordering::SeqCst),
            started_at: p.started_at.clone(),
            completed_at: p.completed_at.clone(),
            error: p.error.clone(),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, PhaseData> {
        self.inner.phase.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Default for EmbedJob {
    fn default() -> Self {
        Self::new()
    }
}

fn now() -> String {
    chrono::Utc::now().to_rfc3339()
}
