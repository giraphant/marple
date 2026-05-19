//! Spike 2 — Vault recall check.
//!
//! Run with:
//!   cargo run --manifest-path rust/Cargo.toml --release -p reader-spike --bin spike-vault
//!
//! Goal: take 300 entries from reader/data/index.sqlite, embed them with
//! BGE-M3 via fastembed-rs, store as `entry_vectors_spike` in a fresh
//! sqlite-vec DB, then run the painful query set from
//! reader/vector-proto/query.py and print top-3 per query. Compare against
//! the prototype's MiniLM output (in vector-proto/) by eye.
//!
//! What this verifies (Phase 0 gates from the spec):
//!   - fastembed-rs can load BGE-M3 cold load <30s, RSS <3GB
//!   - sqlite-vec works in rusqlite (auto-extension path)
//!   - 300 entries / full body embed <5 min (project to 13825 <90 min)
//!   - cosine top-K returns the entries we expect (sanity, not full quality)
//!
//! Output: per-query top-3 + timings to stdout, JSON summary to
//! reader/vector-proto/spike-prod-stack.json for the design doc.

use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{Context, Result};
use fastembed::{EmbeddingModel, InitOptions, TextEmbedding};
use rusqlite::{ffi::sqlite3_auto_extension, params, Connection, OpenFlags};
use serde::Serialize;

const SAMPLE_LIMIT: usize = 300;
const BATCH: usize = 8;
const BODY_TOKEN_CAP: usize = 8192; // BGE-M3 native; we cut by char proxy 1 tok ≈ 1.5 chars CJK / 4 chars latin

#[derive(Debug, Clone, Serialize)]
struct EntryRow {
    path: String,
    entry_type: String,
    title: Option<String>,
    author: Option<String>,
    preview: Option<String>,
}

#[derive(Debug, Serialize)]
struct QueryReport {
    query: String,
    embed_ms: u128,
    knn_ms: u128,
    top: Vec<TopHit>,
}

#[derive(Debug, Serialize)]
struct TopHit {
    path: String,
    title: String,
    entry_type: String,
    cosine: f64,
}

#[derive(Debug, Serialize)]
struct SpikeReport {
    sample_size: usize,
    cold_load_secs: f32,
    embed_throughput_per_sec: f32,
    embed_total_secs: f32,
    vectors_db_bytes: u64,
    queries: Vec<QueryReport>,
}

fn main() -> Result<()> {
    println!("== spike-vault ==");
    register_sqlite_vec();

    let project_root = project_root();
    let index_db = project_root.join("reader").join("data").join("index.sqlite");
    let out_db = project_root
        .join("reader")
        .join("vector-proto")
        .join("spike-vectors.sqlite");
    let report_path = project_root
        .join("reader")
        .join("vector-proto")
        .join("spike-prod-stack.json");
    println!("  index_db   = {}", index_db.display());
    println!("  out_db     = {}", out_db.display());
    println!("  report     = {}", report_path.display());

    let entries = load_entries(&index_db, SAMPLE_LIMIT)?;
    println!("  loaded {} entries", entries.len());

    let model_cache = project_root.join("reader").join("data").join("models");
    std::fs::create_dir_all(&model_cache)?;

    let cold_t = Instant::now();
    let mut model = TextEmbedding::try_new(
        InitOptions::new(EmbeddingModel::BGEM3)
            .with_show_download_progress(true)
            .with_cache_dir(model_cache),
    )
    .context("init BGE-M3")?;
    let cold_load = cold_t.elapsed().as_secs_f32();
    println!("  cold load = {cold_load:.1}s");

    if out_db.exists() {
        std::fs::remove_file(&out_db)?;
    }
    let conn = Connection::open(&out_db).context("open out_db")?;
    conn.execute_batch(
        "CREATE VIRTUAL TABLE entry_vectors USING vec0(
            path TEXT PRIMARY KEY,
            embedding float[1024] distance_metric=cosine
        );
        CREATE TABLE entry_meta (
            path TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            title TEXT,
            preview TEXT
        );",
    )?;

    let embed_t = Instant::now();
    let body_fetcher = BodyFetcher::open(&index_db)?;
    for chunk in entries.chunks(BATCH) {
        let mut texts = Vec::with_capacity(chunk.len());
        for entry in chunk {
            let body = body_fetcher.body_for(&entry.path).unwrap_or_default();
            let body = truncate_to_chars(&body, BODY_TOKEN_CAP * 4); // safety cap
            let text = format!(
                "passage: {}\n{}\n{}\n{}",
                entry.title.as_deref().unwrap_or(""),
                entry.author.as_deref().unwrap_or(""),
                entry.preview.as_deref().unwrap_or(""),
                body
            );
            texts.push(text);
        }
        let vecs = model
            .embed(texts.clone(), None)
            .with_context(|| format!("embed batch starting at path={}", chunk[0].path))?;
        for (entry, mut v) in chunk.iter().zip(vecs.into_iter()) {
            l2_normalize(&mut v);
            conn.execute(
                "INSERT INTO entry_vectors(path, embedding) VALUES (?, ?)",
                params![entry.path, bytes_of(&v)],
            )?;
            conn.execute(
                "INSERT INTO entry_meta(path, type, title, preview) VALUES (?, ?, ?, ?)",
                params![
                    entry.path,
                    entry.entry_type,
                    entry.title.as_deref().unwrap_or(""),
                    entry.preview.as_deref().unwrap_or("")
                ],
            )?;
        }
        eprintln!("  embedded {}/{}", chunk.last().map(|e| &e.path).unwrap_or(&String::new()), entries.len());
    }
    drop(body_fetcher);
    let embed_total = embed_t.elapsed().as_secs_f32();
    let rate = entries.len() as f32 / embed_total;
    println!(
        "  embed total = {embed_total:.1}s ({rate:.1} entries/s, project 13825 → {:.0} min)",
        13825.0 / rate / 60.0
    );

    // ------- queries -------
    let queries = [
        "phenomenology",
        "phenomenological",
        "hermeneutics",
        "诠释学",
        "biopower",
        "生命权力",
        "AI",
        "身体技术",
        "cyborg",
        "数字技术如何重塑身体边界",
        "technology of the self",
        "fucault",
    ];
    let mut reports = Vec::new();
    for q in queries {
        let prefixed = format!("query: {q}");
        let et = Instant::now();
        let mut qv = model
            .embed(vec![prefixed], None)
            .with_context(|| format!("embed query {q}"))?;
        let mut qvec = qv.swap_remove(0);
        l2_normalize(&mut qvec);
        let embed_ms = et.elapsed().as_millis();

        let kt = Instant::now();
        let mut stmt = conn.prepare(
            "SELECT v.path, m.type, m.title, v.distance
             FROM entry_vectors v JOIN entry_meta m ON m.path = v.path
             WHERE v.embedding MATCH ? AND v.k = 3
             ORDER BY v.distance",
        )?;
        let rows = stmt.query_map(params![bytes_of(&qvec)], |row| {
            Ok(TopHit {
                path: row.get(0)?,
                entry_type: row.get(1)?,
                title: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                cosine: 1.0 - row.get::<_, f64>(3)?, // vec0 returns distance, cos = 1 - d
            })
        })?;
        let top: Vec<TopHit> = rows.collect::<Result<_, _>>()?;
        let knn_ms = kt.elapsed().as_millis();

        println!(
            "\n  q={q:30}  embed={embed_ms:>4}ms  knn={knn_ms:>3}ms"
        );
        for hit in &top {
            println!(
                "    [{:6}] cos={:.3}  {}",
                hit.entry_type.chars().take(6).collect::<String>(),
                hit.cosine,
                hit.title.chars().take(70).collect::<String>()
            );
        }
        reports.push(QueryReport {
            query: q.to_string(),
            embed_ms,
            knn_ms,
            top,
        });
    }

    let report = SpikeReport {
        sample_size: entries.len(),
        cold_load_secs: cold_load,
        embed_throughput_per_sec: rate,
        embed_total_secs: embed_total,
        vectors_db_bytes: std::fs::metadata(&out_db)?.len(),
        queries: reports,
    };
    std::fs::write(&report_path, serde_json::to_vec_pretty(&report)?)?;
    println!("\nwrote {}", report_path.display());

    Ok(())
}

fn project_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("..")
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from(env!("CARGO_MANIFEST_DIR")))
}

fn register_sqlite_vec() {
    unsafe {
        sqlite3_auto_extension(Some(std::mem::transmute(
            sqlite_vec::sqlite3_vec_init as *const (),
        )));
    }
}

fn load_entries(index_db: &Path, limit: usize) -> Result<Vec<EntryRow>> {
    let conn = Connection::open_with_flags(index_db, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .context("open index.sqlite")?;
    let sql = "SELECT path, type, title, author, preview
               FROM entries
               WHERE type IN ('paper-analysis','book-overview','chapter-summary','author-profile')
               ORDER BY rating_score DESC, path
               LIMIT ?";
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(params![limit as i64], |row| {
        Ok(EntryRow {
            path: row.get(0)?,
            entry_type: row.get(1)?,
            title: row.get::<_, Option<String>>(2)?,
            author: row.get::<_, Option<String>>(3)?,
            preview: row.get::<_, Option<String>>(4)?,
        })
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

struct BodyFetcher {
    conn: Connection,
    vault_root: PathBuf,
}

impl BodyFetcher {
    fn open(index_db: &Path) -> Result<Self> {
        // We need to read raw markdown body from vault. The index DB doesn't
        // store full body in a single column we can SELECT here; cheapest:
        // read the markdown file from disk using the entries.path (which is
        // relative to vault/).
        let conn =
            Connection::open_with_flags(index_db, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        let project = project_root();
        Ok(Self {
            conn,
            vault_root: project.join("vault"),
        })
    }
    fn body_for(&self, rel_path: &str) -> Option<String> {
        let _ = &self.conn;
        let full = self.vault_root.join(rel_path);
        let raw = std::fs::read_to_string(&full).ok()?;
        // strip yaml frontmatter
        if let Some(stripped) = raw.strip_prefix("---\n") {
            if let Some(idx) = stripped.find("\n---\n") {
                return Some(stripped[idx + 5..].to_string());
            }
        }
        Some(raw)
    }
}

fn l2_normalize(v: &mut [f32]) {
    let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        for x in v.iter_mut() {
            *x /= norm;
        }
    }
}

fn bytes_of(slice: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(slice.len() * 4);
    for &v in slice {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out
}

fn truncate_to_chars(s: &str, n_chars: usize) -> String {
    s.chars().take(n_chars).collect()
}
