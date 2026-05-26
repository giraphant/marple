//! Delta reconcile (QUA-62): keep the live index in agreement with the vault by
//! diffing per-file mtimes, plus per-file upsert/remove for event-driven use.
//! The default build is model-free, so we exercise this over tiny real fixtures.

use reader_core::{
    build_sqlite_index, load_entries, reconcile_index, remove_entry, upsert_entry, ReaderPaths,
};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

fn temp_paths() -> ReaderPaths {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let seq = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    let root = std::env::temp_dir().join(format!("qua-rc-{}-{}-{}", std::process::id(), nanos, seq));
    let workspace_root = root.clone();
    let vault = workspace_root.join("vault");
    let reader_root = workspace_root.join("reader");
    std::fs::create_dir_all(reader_root.join("data")).unwrap();
    std::fs::create_dir_all(vault.join("notes/.trash")).unwrap();
    ReaderPaths {
        reader_root: reader_root.clone(),
        workspace_root: workspace_root.clone(),
        vault: vault.clone(),
        notes_dir: vault.join("notes"),
        trash_dir: vault.join("notes/.trash"),
        sources: workspace_root.join("sources"),
        translations: workspace_root.join("processing/translations"),
        index_db: reader_root.join("data/index.sqlite"),
        vectors_db: reader_root.join("data/vectors.sqlite"),
        dist: reader_root.join("dist"),
    }
}

fn write_file(paths: &ReaderPaths, rel: &str, contents: &str) {
    let abs = paths.workspace_root.join(rel);
    std::fs::create_dir_all(abs.parent().unwrap()).unwrap();
    std::fs::write(&abs, contents).unwrap();
}

fn entry<'a>(paths: &ReaderPaths, rel: &str) -> Option<reader_core::Entry> {
    load_entries(paths).unwrap().into_iter().find(|e| e.path == rel)
}

#[test]
fn load_entries_rebuilds_legacy_entry_schema() {
    let paths = temp_paths();
    write_file(
        &paths,
        "vault/books/test-book/00-overview.md",
        "---\ntype: book\ntitle: Test Book\npublisher: Test Press\nisbn: 12345\n---\n\n# 测试书\n\nbody\n",
    );
    let conn = rusqlite::Connection::open(&paths.index_db).unwrap();
    conn.execute_batch(
        "CREATE TABLE entries (path TEXT PRIMARY KEY, type TEXT NOT NULL, book TEXT, title TEXT, author TEXT, year_json TEXT, rating_json TEXT, rating_score REAL NOT NULL DEFAULT 0, themes_json TEXT, topic TEXT, source TEXT, doi TEXT, chapters_analyzed INTEGER, annotates TEXT, created TEXT, pdf_slug TEXT, has_pdf INTEGER NOT NULL DEFAULT 0, mtime INTEGER, preview TEXT NOT NULL DEFAULT '');",
    )
    .unwrap();
    drop(conn);

    let entries = load_entries(&paths).unwrap();
    let book = entries
        .iter()
        .find(|e| e.path == "vault/books/test-book/00-overview.md")
        .unwrap();

    assert_eq!(book.title_cn.as_deref(), Some("测试书"));
    assert_eq!(book.publisher.as_deref(), Some("Test Press"));
    assert_eq!(book.isbn.as_deref(), Some("12345"));

    let _ = std::fs::remove_dir_all(&paths.workspace_root);
}

/// A new file added to the vault after the build is picked up by reconcile.
#[test]
fn reconcile_indexes_new_file() {
    let paths = temp_paths();
    write_file(&paths, "vault/papers/p1.md", "---\ntype: paper\ntitle: Paper One\n---\n\nbody\n");
    build_sqlite_index(&paths).unwrap();
    assert_eq!(load_entries(&paths).unwrap().len(), 1);

    write_file(&paths, "vault/papers/p2.md", "---\ntype: paper\ntitle: Paper Two\n---\n\nbody two\n");
    let stats = reconcile_index(&paths).unwrap();

    assert_eq!(stats.upserted, 1, "the one new file should be upserted");
    assert_eq!(load_entries(&paths).unwrap().len(), 2);
    assert!(entry(&paths, "vault/papers/p2.md").is_some());

    let _ = std::fs::remove_dir_all(&paths.workspace_root);
}

/// A modified file is re-indexed with its new metadata and leaves no duplicate.
#[test]
fn reconcile_updates_changed_file() {
    let paths = temp_paths();
    write_file(&paths, "vault/papers/p1.md", "---\ntype: paper\ntitle: Old Title\n---\n\nbody\n");
    build_sqlite_index(&paths).unwrap();

    // Sleep so the rewrite lands in a later millisecond (mtime is the fingerprint).
    std::thread::sleep(Duration::from_millis(15));
    write_file(&paths, "vault/papers/p1.md", "---\ntype: paper\ntitle: New Title\n---\n\nbody\n");
    let stats = reconcile_index(&paths).unwrap();

    assert_eq!(stats.upserted, 1, "the changed file should be re-indexed");
    assert_eq!(load_entries(&paths).unwrap().len(), 1, "no duplicate row");
    assert_eq!(
        entry(&paths, "vault/papers/p1.md").unwrap().title.as_deref(),
        Some("New Title")
    );

    let _ = std::fs::remove_dir_all(&paths.workspace_root);
}

/// A file deleted from the vault is dropped from the index.
#[test]
fn reconcile_removes_deleted_file() {
    let paths = temp_paths();
    write_file(&paths, "vault/papers/p1.md", "---\ntype: paper\ntitle: Keep\n---\n\nbody\n");
    write_file(&paths, "vault/papers/p2.md", "---\ntype: paper\ntitle: Gone\n---\n\nbody\n");
    build_sqlite_index(&paths).unwrap();
    assert_eq!(load_entries(&paths).unwrap().len(), 2);

    std::fs::remove_file(paths.workspace_root.join("vault/papers/p2.md")).unwrap();
    let stats = reconcile_index(&paths).unwrap();

    assert_eq!(stats.removed, 1);
    assert!(entry(&paths, "vault/papers/p2.md").is_none());
    assert!(entry(&paths, "vault/papers/p1.md").is_some());

    let _ = std::fs::remove_dir_all(&paths.workspace_root);
}

/// When nothing changed, reconcile touches nothing and reports it as unchanged.
#[test]
fn reconcile_is_noop_when_unchanged() {
    let paths = temp_paths();
    write_file(&paths, "vault/papers/p1.md", "---\ntype: paper\ntitle: Stable\n---\n\nbody\n");
    build_sqlite_index(&paths).unwrap();

    let stats = reconcile_index(&paths).unwrap();
    assert_eq!(stats.upserted, 0);
    assert_eq!(stats.removed, 0);
    assert_eq!(stats.unchanged, 1);

    let _ = std::fs::remove_dir_all(&paths.workspace_root);
}

/// upsert_entry re-indexes one path on demand (the watcher's per-event hook).
#[test]
fn upsert_entry_indexes_single_file() {
    let paths = temp_paths();
    write_file(&paths, "vault/papers/p1.md", "---\ntype: paper\ntitle: One\n---\n\nbody\n");
    build_sqlite_index(&paths).unwrap();

    write_file(&paths, "vault/papers/p2.md", "---\ntype: paper\ntitle: Two\n---\n\nbody\n");
    let indexed = upsert_entry(&paths, "vault/papers/p2.md").unwrap();

    assert!(indexed, "a real entry should report as indexed");
    assert!(entry(&paths, "vault/papers/p2.md").is_some());

    let _ = std::fs::remove_dir_all(&paths.workspace_root);
}

/// remove_entry drops one path on demand (delete/rename events).
#[test]
fn remove_entry_drops_single_file() {
    let paths = temp_paths();
    write_file(&paths, "vault/papers/p1.md", "---\ntype: paper\ntitle: One\n---\n\nbody\n");
    build_sqlite_index(&paths).unwrap();

    let removed = remove_entry(&paths, "vault/papers/p1.md").unwrap();

    assert!(removed);
    assert!(entry(&paths, "vault/papers/p1.md").is_none());

    let _ = std::fs::remove_dir_all(&paths.workspace_root);
}

/// The live index DB must be in WAL mode so readers never block the writer.
#[test]
fn index_db_is_wal_after_build() {
    let paths = temp_paths();
    write_file(
        &paths,
        "vault/papers/a.md",
        "---\ntype: paper-analysis\ntitle: A\n---\nbody",
    );
    reconcile_index(&paths).unwrap();
    let conn = rusqlite::Connection::open_with_flags(
        &paths.index_db,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    let mode: String = conn
        .query_row("PRAGMA journal_mode", [], |r| r.get(0))
        .unwrap();
    assert_eq!(mode.to_lowercase(), "wal");

    let _ = std::fs::remove_dir_all(&paths.workspace_root);
}
