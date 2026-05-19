//! Spike 1 — Infrastructure check: BGE-M3 + sqlite-vec.
//!
//! Run with:
//!   cargo run --manifest-path rust/Cargo.toml -p reader-spike --bin spike-infra
//!
//! What it does:
//!   1. Open a fresh sqlite in /tmp, load the sqlite-vec extension,
//!      create + populate a tiny vec0 table to confirm rusqlite ↔ sqlite-vec
//!      works on this machine.
//!   2. Initialize BGE-M3 via fastembed-rs, time the cold load + first embed.
//!      First run downloads the ONNX model into the cache directory
//!      (default ~/.cache/fastembed or override via FASTEMBED_CACHE_DIR).
//!   3. Embed a handful of mixed CN/EN sentences and print L2 norms so we
//!      know normalization is in our hands, not the model's.
//!
//! No vault data is touched. This is purely a "do the two new deps work?"
//! check. The next spike (spike-vault.rs, TBD) will load real entries.

use std::time::Instant;

use anyhow::{Context, Result};
use rusqlite::{ffi::sqlite3_auto_extension, params, Connection};

fn main() -> Result<()> {
    println!("== spike-infra ==");
    println!("crate versions:");
    println!("  fastembed  = {}", env!("CARGO_PKG_VERSION"));
    println!();

    sqlite_vec_check()?;
    println!();
    fastembed_check()?;

    println!();
    println!("== spike-infra done ==");
    Ok(())
}

fn sqlite_vec_check() -> Result<()> {
    println!("-- sqlite-vec check --");
    let path = std::env::temp_dir().join("reader-spike-vec.sqlite");
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    // Register sqlite-vec as an auto-extension; any Connection opened after
    // this call gets vec functions available automatically.
    unsafe {
        sqlite3_auto_extension(Some(std::mem::transmute(
            sqlite_vec::sqlite3_vec_init as *const (),
        )));
    }
    let conn = Connection::open(&path).context("open sqlite")?;
    let version: String = conn
        .query_row("SELECT vec_version()", [], |row| row.get(0))
        .context("call vec_version()")?;
    println!("  vec_version() = {version}");

    conn.execute(
        "CREATE VIRTUAL TABLE demo USING vec0(
            id INTEGER PRIMARY KEY,
            embedding float[4] distance_metric=cosine
        )",
        [],
    )?;
    let v1 = bytes_of(&[1.0_f32, 0.0, 0.0, 0.0]);
    let v2 = bytes_of(&[0.9_f32, 0.1, 0.0, 0.0]);
    let v3 = bytes_of(&[0.0_f32, 1.0, 0.0, 0.0]);
    conn.execute("INSERT INTO demo(id, embedding) VALUES (1, ?)", params![v1])?;
    conn.execute("INSERT INTO demo(id, embedding) VALUES (2, ?)", params![v2])?;
    conn.execute("INSERT INTO demo(id, embedding) VALUES (3, ?)", params![v3])?;

    let query = bytes_of(&[1.0_f32, 0.0, 0.0, 0.0]);
    let mut stmt = conn.prepare(
        "SELECT id, distance FROM demo WHERE embedding MATCH ? AND k = 3 ORDER BY distance",
    )?;
    let rows = stmt.query_map(params![query], |row| {
        Ok((row.get::<_, i64>(0)?, row.get::<_, f64>(1)?))
    })?;
    println!("  KNN top-3 of [1,0,0,0]:");
    for r in rows {
        let (id, d) = r?;
        println!("    id={id}  distance={d:.4}");
    }
    Ok(())
}

fn fastembed_check() -> Result<()> {
    use fastembed::{EmbeddingModel, InitOptions, TextEmbedding};

    println!("-- fastembed BGE-M3 check --");
    let cache_dir = std::env::var("FASTEMBED_CACHE_DIR")
        .ok()
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            // project-local cache so we don't pollute ~/.cache
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("..")
                .join("..")
                .join("data")
                .join("models")
        });
    std::fs::create_dir_all(&cache_dir)?;
    println!("  cache_dir = {}", cache_dir.display());

    let t0 = Instant::now();
    let mut model = TextEmbedding::try_new(
        InitOptions::new(EmbeddingModel::BGEM3)
            .with_show_download_progress(true)
            .with_cache_dir(cache_dir),
    )
    .context("init BGE-M3")?;
    println!("  cold load = {:.1}s", t0.elapsed().as_secs_f32());

    let probes = [
        "passage: phenomenology of perception",
        "passage: 身体技术的政治维度",
        "query: cyborg manifesto",
        "query: 生命权力",
    ];
    let t1 = Instant::now();
    let vectors = model
        .embed(probes.iter().map(|s| s.to_string()).collect::<Vec<_>>(), None)
        .context("embed probes")?;
    let dt = t1.elapsed().as_secs_f32();
    println!(
        "  embed {} sentences = {:.2}s ({:.0} ms/sentence)",
        probes.len(),
        dt,
        dt * 1000.0 / probes.len() as f32
    );

    for (text, v) in probes.iter().zip(vectors.iter()) {
        let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        let len = v.len();
        println!("  {:30}  dim={}  ||v||={:.4}", &text[..text.len().min(30)], len, norm);
    }

    Ok(())
}

fn bytes_of(slice: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(slice.len() * 4);
    for &v in slice {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out
}
