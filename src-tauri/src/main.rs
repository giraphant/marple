use std::path::PathBuf;

use reader_core::ReaderPaths;

/// The reader root mirrors how `reader-api` resolves it: the `reader/` directory.
/// During `tauri dev` the binary's cwd is the crate dir, so derive from the
/// compiled-in manifest path instead (CARGO_MANIFEST_DIR = reader/src-tauri).
fn reader_root() -> PathBuf {
    if let Ok(p) = std::env::var("READER_ROOT") {
        return PathBuf::from(p);
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .canonicalize()
        .expect("resolve reader root")
}

fn main() {
    let paths = ReaderPaths::from_reader_root(reader_root()).expect("init reader paths");
    tauri::Builder::default()
        .manage(paths)
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
