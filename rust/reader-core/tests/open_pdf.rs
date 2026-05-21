//! QUA-55: resolve_source_pdf path safety. The OS opener (open_in_system_app)
//! is not exercised here — it would launch a GUI app — but the resolution that
//! gates it is pure and must reject traversal / missing / non-pdf inputs.

use reader_core::{resolve_source_pdf, ReaderError, ReaderPaths};
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_paths() -> ReaderPaths {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let root = std::env::temp_dir().join(format!("qua-pdf-{}-{}", std::process::id(), nanos));
    let workspace_root = root.clone();
    let vault = workspace_root.join("vault");
    let reader_root = workspace_root.join("reader");
    std::fs::create_dir_all(reader_root.join("data")).unwrap();
    std::fs::create_dir_all(vault.join("notes/.trash")).unwrap();
    std::fs::create_dir_all(workspace_root.join("sources")).unwrap();
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
fn resolves_existing_source_pdf() {
    let paths = temp_paths();
    let pdf = paths.sources.join("smith-body-2020.pdf");
    std::fs::write(&pdf, b"%PDF-1.4 test").unwrap();

    let resolved = resolve_source_pdf(&paths, "smith-body-2020").expect("should resolve");
    assert_eq!(resolved, pdf.canonicalize().unwrap());
}

#[test]
fn resolves_truncated_slug_via_fuzzy_fallback() {
    // The vault slug dropped a title word; no exact file exists, but the source
    // dir holds the full-title PDF — fuzzy fallback should still find it.
    let paths = temp_paths();
    let pdf = paths
        .sources
        .join("ahmed-queer-phenomenology-2006.pdf");
    std::fs::write(&pdf, b"%PDF-1.4 test").unwrap();

    let resolved = resolve_source_pdf(&paths, "ahmed-orientations-queer-phenomenology-2006")
        .expect("fuzzy fallback should resolve");
    assert_eq!(resolved, pdf.canonicalize().unwrap());
}

#[test]
fn rejects_empty_slug() {
    let paths = temp_paths();
    assert!(matches!(
        resolve_source_pdf(&paths, "   "),
        Err(ReaderError::BadRequest(_))
    ));
}

#[test]
fn rejects_missing_pdf() {
    let paths = temp_paths();
    assert!(matches!(
        resolve_source_pdf(&paths, "does-not-exist"),
        Err(ReaderError::NotFound(_))
    ));
}

#[test]
fn rejects_traversal_out_of_sources() {
    let paths = temp_paths();
    // A real file outside sources/ that the slug tries to reach via `../`.
    std::fs::write(paths.vault.join("notes/secret.pdf"), b"%PDF").unwrap();
    let err = resolve_source_pdf(&paths, "../vault/notes/secret");
    assert!(
        matches!(err, Err(ReaderError::Forbidden(_))),
        "traversal must be forbidden, got {err:?}"
    );
}
