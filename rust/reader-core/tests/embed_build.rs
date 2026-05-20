//! Model-free coverage of the embedding build's progress plumbing. An empty
//! vault short-circuits before the ~2.3 GB model loads, so we can exercise
//! `build_embeddings_with_progress` end-to-end (vectors.sqlite + meta + the
//! progress callback) without downloading anything.

use reader_core::ReaderPaths;
use rusqlite::{Connection, OpenFlags};
use std::sync::Mutex;

fn tempdir_for_test() -> std::path::PathBuf {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let p = std::env::temp_dir().join(format!("reader-embed-build-{nonce}"));
    std::fs::create_dir_all(&p).unwrap();
    p
}

#[test]
fn empty_vault_build_reports_zero_progress_and_writes_vectors_db() {
    let tmp = tempdir_for_test();
    let reader_root = tmp.join("reader");
    let vault = tmp.join("vault");
    std::fs::create_dir_all(reader_root.join("data")).unwrap();
    std::fs::create_dir_all(vault.join("notes/.trash")).unwrap();

    // build_embeddings requires an existing index.sqlite; its contents are not
    // read by the embed pass, so a placeholder file is enough.
    let index_db = reader_root.join("data/index.sqlite");
    std::fs::write(&index_db, b"placeholder").unwrap();

    let paths = ReaderPaths {
        reader_root: reader_root.clone(),
        workspace_root: tmp.clone(),
        vault: vault.clone(),
        notes_dir: vault.join("notes"),
        trash_dir: vault.join("notes/.trash"),
        sources: tmp.join("sources"),
        index_db,
        vectors_db: reader_root.join("data/vectors.sqlite"),
        dist: reader_root.join("dist"),
    };

    let progress: Mutex<Vec<(usize, usize)>> = Mutex::new(Vec::new());
    let n = reader_core::build_embeddings_with_progress(&paths, &|done, total| {
        progress.lock().unwrap().push((done, total));
    })
    .expect("empty-vault embed build must succeed without a model");

    assert_eq!(n, 0, "no entries to embed");
    assert!(paths.vectors_db.is_file(), "vectors.sqlite is published");

    // Progress was reported and reflects an empty corpus.
    let calls = progress.lock().unwrap().clone();
    assert!(!calls.is_empty(), "progress callback must fire at least once");
    assert_eq!(calls.last().copied(), Some((0, 0)));

    // entry_vectors exists (empty) and meta records the model id.
    reader_core::init_sqlite_vec();
    let conn =
        Connection::open_with_flags(&paths.vectors_db, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let count: i64 = conn
        .query_row("SELECT count(*) FROM entry_vectors", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 0);
    let model: String = conn
        .query_row(
            "SELECT value FROM meta WHERE key = 'embed_model'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(model, "BAAI/bge-m3");
}

#[test]
fn build_embeddings_errors_when_index_missing() {
    let tmp = tempdir_for_test();
    let reader_root = tmp.join("reader");
    let vault = tmp.join("vault");
    std::fs::create_dir_all(reader_root.join("data")).unwrap();
    std::fs::create_dir_all(vault.join("notes/.trash")).unwrap();

    let paths = ReaderPaths {
        reader_root: reader_root.clone(),
        workspace_root: tmp.clone(),
        vault: vault.clone(),
        notes_dir: vault.join("notes"),
        trash_dir: vault.join("notes/.trash"),
        sources: tmp.join("sources"),
        index_db: reader_root.join("data/index.sqlite"), // does NOT exist
        vectors_db: reader_root.join("data/vectors.sqlite"),
        dist: reader_root.join("dist"),
    };

    let err = reader_core::build_embeddings_with_progress(&paths, &|_, _| {});
    assert!(err.is_err(), "missing index.sqlite must error, not silently build");
}
