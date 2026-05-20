use reader_core::vector::{ModelHandle, ModelState};
use std::time::Duration;

#[tokio::test]
async fn starts_uninitialized() {
    let handle = ModelHandle::new();
    assert!(matches!(handle.snapshot().await, ModelState::Uninitialized));
}

#[tokio::test]
async fn disabled_state_is_sticky() {
    let handle = ModelHandle::new();
    handle.disable("sqlite-vec missing").await;
    let s = handle.snapshot().await;
    assert!(matches!(s, ModelState::Disabled(_)));

    // ensure_loaded should never transition out of Disabled
    let result = handle.ensure_loaded_for_test_fail().await;
    assert!(result.is_err());
    assert!(matches!(handle.snapshot().await, ModelState::Disabled(_)));
}

/// Regression for Codex review finding #2: hybrid mode against an index
/// built by an older reader-index (no `entry_vectors` table) must NOT 500.
/// We use the public `search_entries` API with mode=Hybrid and assert it
/// still returns results (with the lex-fallback marker).
#[test]
fn hybrid_on_legacy_index_falls_back_to_lex() {
    use reader_core::{ReaderPaths, SearchMode, SearchOptions};
    use rusqlite::Connection;
    reader_core::init_sqlite_vec();

    // Build a minimal index file that has entries but no entry_vectors.
    let tmpdir = tempdir_for_test();
    let reader_root = tmpdir.join("reader");
    let vault = tmpdir.join("vault");
    std::fs::create_dir_all(reader_root.join("data")).unwrap();
    std::fs::create_dir_all(vault.join("notes/.trash")).unwrap();
    let index_db = reader_root.join("data/index.sqlite");

    let conn = Connection::open(&index_db).unwrap();
    conn.execute_batch(
        "CREATE TABLE entries (path TEXT PRIMARY KEY, type TEXT NOT NULL, book TEXT, title TEXT, author TEXT, year_json TEXT, rating_json TEXT, rating_score REAL NOT NULL DEFAULT 0, themes_json TEXT, topic TEXT, source TEXT, doi TEXT, chapters_analyzed INTEGER, annotates TEXT, created TEXT, pdf_slug TEXT, has_pdf INTEGER NOT NULL DEFAULT 0, mtime INTEGER, preview TEXT NOT NULL DEFAULT '');
         CREATE VIRTUAL TABLE entry_search USING fts5(path UNINDEXED, type UNINDEXED, title, author, book, themes, topic, source, year, preview, doi, body);
         CREATE VIRTUAL TABLE entry_trigram USING fts5(path UNINDEXED, type UNINDEXED, text, tokenize = 'trigram');
         CREATE TABLE entry_text (path TEXT PRIMARY KEY, search_text TEXT NOT NULL);",
    )
    .unwrap();
    conn.execute(
        "INSERT INTO entries(path, type, title, preview) VALUES ('p/a.md', 'paper-analysis', 'Alpha', 'about alpha')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO entry_search(path, type, title, author, book, themes, topic, source, year, preview, doi, body) VALUES ('p/a.md', 'paper-analysis', 'Alpha', NULL, NULL, NULL, NULL, NULL, NULL, 'about alpha', NULL, 'alpha body')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO entry_trigram(path, type, text) VALUES ('p/a.md', 'paper-analysis', 'alpha alpha body')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO entry_text(path, search_text) VALUES ('p/a.md', 'alpha alpha body')",
        [],
    )
    .unwrap();
    drop(conn);

    let paths = ReaderPaths {
        reader_root: reader_root.clone(),
        workspace_root: tmpdir.clone(),
        vault: vault.clone(),
        notes_dir: vault.join("notes"),
        trash_dir: vault.join("notes/.trash"),
        sources: tmpdir.join("sources"),
        index_db,
        vectors_db: reader_root.join("data/vectors.sqlite"),
        dist: reader_root.join("dist"),
    };
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let model = reader_core::vector::ModelHandle::new();
    let hits = reader_core::search_entries(
        &paths,
        SearchOptions {
            query: "alpha".to_string(),
            entry_type: None,
            min_rating: None,
            theme: None,
            limit: 5,
            mode: SearchMode::Hybrid,
        },
        Some(&model),
        rt.handle(),
    )
    .expect("hybrid on legacy index must not error");
    assert!(!hits.is_empty(), "lex fallback should still return alpha");
    assert!(
        hits.iter().any(|h| h.source.contains("lex-fallback:no-vectors")),
        "fallback marker present: {:?}",
        hits.iter().map(|h| &h.source).collect::<Vec<_>>()
    );
}

fn tempdir_for_test() -> std::path::PathBuf {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let p = std::env::temp_dir().join(format!("reader-core-test-{nonce}"));
    std::fs::create_dir_all(&p).unwrap();
    p
}

#[test]
fn vec_search_accept_filter_excludes_rejected() {
    use rusqlite::Connection;
    use std::collections::HashMap;
    reader_core::init_sqlite_vec();
    // Vectors now live in their own DB with no entries table; the type/rating
    // filter is applied in Rust via the `accept` closure.
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(
        "CREATE VIRTUAL TABLE entry_vectors USING vec0(path TEXT PRIMARY KEY, embedding float[4] distance_metric=cosine);",
    )
    .unwrap();
    let bytes = |v: [f32; 4]| -> Vec<u8> { v.iter().flat_map(|f| f.to_le_bytes()).collect() };
    let mut ty: HashMap<&str, &str> = HashMap::new();
    for (path, t, v) in [
        ("a.md", "paper-analysis", [1.0_f32, 0.0, 0.0, 0.0]),
        ("b.md", "book-overview", [0.9, 0.1, 0.0, 0.0]),
        ("c.md", "paper-analysis", [0.0, 1.0, 0.0, 0.0]),
    ] {
        ty.insert(path, t);
        conn.execute(
            "INSERT INTO entry_vectors(path, embedding) VALUES (?, ?)",
            rusqlite::params![path, bytes(v)],
        )
        .unwrap();
    }
    let q = [1.0_f32, 0.0, 0.0, 0.0];
    let accept = |path: &str| ty.get(path).copied() == Some("paper-analysis");
    let hits = reader_core::vector::vec_search(&conn, &q, 5, accept).unwrap();
    let paths: Vec<_> = hits.iter().map(|h| h.path.as_str()).collect();
    assert!(paths.contains(&"a.md"));
    assert!(!paths.contains(&"b.md"), "accept filter must exclude book-overview");
}

#[tokio::test]
async fn failed_state_backs_off() {
    let handle = ModelHandle::new();
    handle
        .force_failed("simulated", Duration::from_millis(50))
        .await;
    // immediately retry → still Failed
    assert!(handle.ensure_loaded_for_test_fail().await.is_err());
    let s = handle.snapshot().await;
    assert!(matches!(s, ModelState::Failed { .. }));
}
