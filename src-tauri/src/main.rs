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

#[tauri::command]
fn entry(paths: tauri::State<ReaderPaths>, path: String) -> Result<serde_json::Value, String> {
    let entry = reader_core::parse_entry(&paths, &path).map_err(|e| e.to_string())?;
    Ok(serde_json::json!({ "entry": entry }))
}

#[tauri::command]
fn entry_text(paths: tauri::State<ReaderPaths>, path: String) -> Result<String, String> {
    let abs = reader_core::resolve_get_path(&paths, &path).map_err(|e| e.to_string())?;
    std::fs::read_to_string(&abs).map_err(|e| e.to_string())
}

#[tauri::command]
fn files(paths: tauri::State<ReaderPaths>, since: Option<f64>) -> Result<serde_json::Value, String> {
    let all = reader_core::list_vault_files(&paths).map_err(|e| e.to_string())?;
    let total = all.len();
    let items: Vec<_> = match since {
        Some(s) => all.into_iter().filter(|f| f.mtime.map_or(true, |m| m as f64 > s)).collect(),
        None => all,
    };
    Ok(serde_json::json!({ "items": items, "total": total }))
}

fn main() {
    let paths = ReaderPaths::from_reader_root(reader_root()).expect("init reader paths");
    tauri::Builder::default()
        .manage(paths)
        .invoke_handler(tauri::generate_handler![index, entry, entry_text, files])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
