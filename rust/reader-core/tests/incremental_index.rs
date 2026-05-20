//! Incremental single-file index maintenance (QUA-53).
//!
//! Builds an index over an EMPTY vault — which skips the BGE-M3 embedding step
//! (see `embed_entries_into_staging`'s empty-entries early return) — so this
//! runs in a normal `cargo test` with no 2.3 GB model download. It then checks
//! that `index_upsert_file` / `index_remove_file` keep `load_entries` current.

use reader_core::{
    build_sqlite_index, index_remove_file, index_upsert_file, load_entries, ReaderPaths,
};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_paths() -> ReaderPaths {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let root = std::env::temp_dir().join(format!("qua-inc-{}-{}", std::process::id(), nanos));
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
        index_db: reader_root.join("data/index.sqlite"),
        dist: reader_root.join("dist"),
    }
}

fn write_note(paths: &ReaderPaths, rel: &str, heading: &str) -> PathBuf {
    let abs = paths.workspace_root.join(rel);
    std::fs::create_dir_all(abs.parent().unwrap()).unwrap();
    let body = format!("---\ntype: note\ntitle: placeholder\n---\n\n# {heading}\n");
    std::fs::write(&abs, body).unwrap();
    abs
}

#[test]
fn upsert_then_remove_keeps_load_entries_current() {
    let paths = temp_paths();

    // Empty-vault build → valid but empty index, no model load.
    build_sqlite_index(&paths).unwrap();
    assert_eq!(load_entries(&paths).unwrap().len(), 0, "fresh index is empty");

    // A new file is invisible until indexed.
    let rel = "vault/notes/qua53.md";
    write_note(&paths, rel, "First Title");
    index_upsert_file(&paths, rel).unwrap();

    let after_insert = load_entries(&paths).unwrap();
    assert_eq!(after_insert.len(), 1, "upsert inserts the new entry");
    assert_eq!(after_insert[0].path, rel);
    assert_eq!(after_insert[0].title.as_deref(), Some("First Title"));

    // Editing the file + re-upserting updates in place (no duplicate row).
    write_note(&paths, rel, "Second Title");
    index_upsert_file(&paths, rel).unwrap();

    let after_update = load_entries(&paths).unwrap();
    assert_eq!(after_update.len(), 1, "re-upsert replaces, not duplicates");
    assert_eq!(after_update[0].title.as_deref(), Some("Second Title"));

    // Removing drops it from the index.
    index_remove_file(&paths, rel).unwrap();
    assert_eq!(load_entries(&paths).unwrap().len(), 0, "remove deletes the row");

    let _ = std::fs::remove_dir_all(&paths.workspace_root);
}

#[test]
fn upsert_is_noop_when_index_db_missing() {
    let paths = temp_paths();
    // No build_sqlite_index call → no index_db on disk.
    write_note(&paths, "vault/notes/orphan.md", "Orphan");
    // Should not error: nothing to update yet.
    index_upsert_file(&paths, "vault/notes/orphan.md").unwrap();
    let _ = std::fs::remove_dir_all(&paths.workspace_root);
}
