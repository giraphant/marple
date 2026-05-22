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

#[tauri::command]
fn index(paths: tauri::State<ReaderPaths>) -> Result<serde_json::Value, String> {
    let items = reader_core::load_entries(&paths).map_err(|e| e.to_string())?;
    Ok(serde_json::json!({ "items": items }))
}

fn main() {
    let paths = ReaderPaths::from_reader_root(reader_root()).expect("init reader paths");
    tauri::Builder::default()
        .manage(paths)
        .invoke_handler(tauri::generate_handler![index])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
