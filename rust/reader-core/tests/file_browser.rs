//! File-browser data layer (QUA-53): the default index build is model-free, so
//! we can build over a small real fixture here. Covers list_vault_files (the
//! "what exists" view) and parse_entry (live single-file metadata, no DB) —
//! including files NOT yet in the index, and non-entries.

use reader_core::{build_sqlite_index, list_vault_files, load_entries, parse_entry, ReaderPaths};
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_paths() -> ReaderPaths {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let root = std::env::temp_dir().join(format!("qua-fb-{}-{}", std::process::id(), nanos));
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
        vectors_db: reader_root.join("data/vectors.sqlite"),
        dist: reader_root.join("dist"),
    }
}

fn write_file(paths: &ReaderPaths, rel: &str, contents: &str) {
    let abs = paths.workspace_root.join(rel);
    std::fs::create_dir_all(abs.parent().unwrap()).unwrap();
    std::fs::write(&abs, contents).unwrap();
}

#[test]
fn build_then_list_and_parse() {
    let paths = temp_paths();
    write_file(&paths, "vault/notes/n1.md", "---\ntype: note\n---\n\n# Note One\n");
    write_file(
        &paths,
        "vault/papers/p1.md",
        "---\ntype: paper\ntitle: Paper One\nyear: 2020\n---\n\nbody text\n",
    );

    // Default build is model-free, so building a non-empty fixture is cheap.
    build_sqlite_index(&paths).unwrap();
    assert_eq!(load_entries(&paths).unwrap().len(), 2);

    // list_vault_files = the file-browser's "what exists".
    let files = list_vault_files(&paths).unwrap();
    let listed: Vec<&str> = files.iter().map(|f| f.path.as_str()).collect();
    assert!(listed.contains(&"vault/notes/n1.md"));
    assert!(listed.contains(&"vault/papers/p1.md"));
    assert!(files.iter().all(|f| f.mtime.is_some()));

    // parse_entry reads metadata straight from the file (no DB), same rules.
    let p = parse_entry(&paths, "vault/papers/p1.md").unwrap().expect("paper entry");
    assert_eq!(p.title.as_deref(), Some("Paper One"));
    assert_eq!(p.entry_type, "paper-analysis"); // canonical_type maps "paper"

    // A brand-new file NOT in the index is still parseable live.
    write_file(&paths, "vault/notes/fresh.md", "---\ntype: note\n---\n\n# Fresh\n");
    let fresh = parse_entry(&paths, "vault/notes/fresh.md").unwrap().expect("fresh entry");
    assert_eq!(fresh.title.as_deref(), Some("Fresh"));

    // Frontmatter but no usable type -> not an entry (browser skips it).
    write_file(&paths, "vault/notes/notype.md", "---\nfoo: bar\n---\n\nx\n");
    assert!(parse_entry(&paths, "vault/notes/notype.md").unwrap().is_none());

    // Missing file -> None (e.g. deleted between listing and parse).
    assert!(parse_entry(&paths, "vault/notes/does-not-exist.md").unwrap().is_none());

    let _ = std::fs::remove_dir_all(&paths.workspace_root);
}
