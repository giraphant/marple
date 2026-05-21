//! End-to-end smoke test: build a 2-entry SQLite index from a fixture vault,
//! run lex vs hybrid search on a cross-language query, and assert that the
//! English query also surfaces the Chinese entry in hybrid mode.
//!
//! Marked `#[ignore]` because the first run downloads BGE-M3 (~2.3 GB).
//! Once cached under reader/data/models/, subsequent runs take a couple of
//! minutes. Trigger with:
//!   cargo test --release -p reader-core --test integration_hybrid -- --ignored --nocapture

use reader_core::{ReaderPaths, SearchMode, SearchOptions};
use std::path::PathBuf;

fn fixture_paths() -> ReaderPaths {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let workspace_root = manifest.join("tests/fixtures");
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
        translations: workspace_root.join("processing").join("translations"),
    }
}

#[test]
#[ignore = "downloads BGE-M3 (~2.3 GB) the first time; opt-in"]
fn fixture_vault_round_trip() {
    let paths = fixture_paths();
    let _ = std::fs::remove_file(&paths.index_db);
    reader_core::build_sqlite_index(&paths).unwrap();

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let model = reader_core::vector::ModelHandle::with_cache_dir(
        paths.reader_root.join("data/models"),
    );

    let opts = |q: &str, m: SearchMode| SearchOptions {
        query: q.to_string(),
        entry_type: None,
        min_rating: None,
        theme: None,
        limit: 5,
        mode: m,
    };

    // Lex mode: English query only finds the English doc (no shared tokens).
    let lex_en = reader_core::search_entries(
        &paths,
        opts("cyborg manifesto", SearchMode::Lex),
        None,
        rt.handle(),
    )
    .unwrap();
    assert!(
        lex_en.iter().any(|h| h.entry.path.contains("sample-en")),
        "lex EN should surface English doc: {:?}",
        lex_en.iter().map(|h| &h.entry.path).collect::<Vec<_>>()
    );
    assert!(
        !lex_en.iter().any(|h| h.entry.path.contains("sample-zh")),
        "lex EN must NOT surface Chinese doc"
    );

    // Hybrid mode: same query reaches the Chinese doc via vec recall.
    let hybrid_en = reader_core::search_entries(
        &paths,
        opts("cyborg manifesto", SearchMode::Hybrid),
        Some(&model),
        rt.handle(),
    )
    .unwrap();
    assert!(
        hybrid_en.iter().any(|h| h.entry.path.contains("sample-zh")),
        "hybrid EN should surface 赛博格宣言: {:?}",
        hybrid_en.iter().map(|h| (&h.entry.path, &h.source, h.score)).collect::<Vec<_>>()
    );
}
