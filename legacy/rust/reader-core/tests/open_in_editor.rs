//! QUA-72: resolve_editable_md path safety + editor_command construction. The OS
//! launcher (open_in_editor) is not exercised here — it would open a GUI app —
//! but the resolution that gates it and the no-shell command it builds are pure
//! and must reject traversal / missing / non-md inputs and keep the app name as
//! its own argument.

use reader_core::{editor_command, resolve_editable_md, ReaderError, ReaderPaths};
use std::ffi::OsString;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_paths() -> ReaderPaths {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let root = std::env::temp_dir().join(format!("qua-editor-{}-{}", std::process::id(), nanos));
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
fn resolves_an_existing_vault_note() {
    let paths = temp_paths();
    let note = paths.notes_dir.join("hello.md");
    std::fs::write(&note, b"---\ntype: note\n---\n").unwrap();
    let resolved = resolve_editable_md(&paths, "vault/notes/hello.md").expect("should resolve");
    assert_eq!(resolved, note.canonicalize().unwrap());
}

#[test]
fn rejects_missing_file() {
    let paths = temp_paths();
    assert!(matches!(
        resolve_editable_md(&paths, "vault/notes/ghost.md"),
        Err(ReaderError::NotFound(_))
    ));
}

#[test]
fn rejects_non_markdown() {
    let paths = temp_paths();
    std::fs::write(paths.notes_dir.join("x.txt"), b"x").unwrap();
    assert!(matches!(
        resolve_editable_md(&paths, "vault/notes/x.txt"),
        Err(ReaderError::Unsupported(_))
    ));
}

#[test]
fn rejects_traversal_out_of_vault() {
    let paths = temp_paths();
    std::fs::write(paths.workspace_root.join("outside.md"), b"x").unwrap();
    let err = resolve_editable_md(&paths, "vault/../outside.md");
    assert!(
        matches!(err, Err(ReaderError::Forbidden(_))),
        "traversal must be forbidden, got {err:?}"
    );
}

#[test]
#[cfg(target_os = "macos")]
fn editor_command_keeps_app_name_as_one_argument() {
    let path = Path::new("/tmp/x.md");
    let (prog, args) = editor_command("Visual Studio Code", path).unwrap();
    assert_eq!(prog, "open");
    assert_eq!(
        args,
        vec![
            OsString::from("-a"),
            OsString::from("Visual Studio Code"),
            OsString::from("/tmp/x.md"),
        ]
    );
}

#[test]
#[cfg(target_os = "macos")]
fn editor_command_empty_app_uses_default_handler() {
    let (prog, args) = editor_command("", Path::new("/tmp/x.md")).unwrap();
    assert_eq!(prog, "open");
    assert_eq!(args, vec![OsString::from("/tmp/x.md")]);
}
