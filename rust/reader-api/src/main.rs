use std::{env, fs, net::SocketAddr, path::PathBuf, sync::Arc, time::Instant};

use axum::{
    body::{Body, Bytes},
    extract::{Path, Query, State},
    http::{header, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use reader_core::{ReaderError, ReaderPaths};
use serde::Deserialize;
use serde_json::json;
use tower_http::cors::{Any, CorsLayer};

#[derive(Clone)]
struct AppState {
    paths: Arc<ReaderPaths>,
    model: reader_core::vector::ModelHandle,
    reindex_lock: Arc<tokio::sync::Mutex<()>>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    reader_core::init_sqlite_vec();

    let reader_root = env::var("READER_ROOT")
        .map(PathBuf::from)
        .unwrap_or(env::current_dir()?);
    let paths = Arc::new(ReaderPaths::from_reader_root(reader_root)?);
    let port = env::var("PORT")
        .ok()
        .and_then(|s| s.parse::<u16>().ok())
        .unwrap_or(5174);

    let model = reader_core::vector::ModelHandle::with_cache_dir(
        paths.reader_root.join("data").join("models"),
    );
    let state = AppState {
        paths,
        model,
        reindex_lock: Arc::new(tokio::sync::Mutex::new(())),
    };

    let app = Router::new()
        .route("/api/index", get(api_index))
        .route("/api/files", get(api_files))
        .route("/api/entry", get(api_entry))
        .route("/api/search", get(api_search))
        .route("/api/reindex", post(api_reindex))
        .route("/api/trash", get(api_trash_list))
        .route("/api/trash/:name/restore", post(api_trash_restore))
        .route("/api/trash/:name", delete(api_trash_purge))
        .route(
            "/vault/*path",
            get(get_vault_file)
                .put(put_vault_file)
                .post(post_vault_note)
                .delete(delete_vault_note),
        )
        .route("/sources/*path", get(get_source_file))
        .route("/reader/data/*path", get(get_reader_data_file))
        .route("/reader", get(get_reader_dist_root))
        .route("/reader/", get(get_reader_dist_root))
        .route("/reader/*path", get(get_reader_dist_file))
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .with_state(state);

    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    println!("reader api at http://localhost:{port}");
    println!("GET    /api/index              -> read entries from data/index.sqlite");
    println!("GET    /api/files              -> list vault files (path + mtime)");
    println!("GET    /api/entry?path=...     -> live-parse one vault file's metadata");
    println!("GET    /api/search?q=...       -> search entries with SQLite FTS");
    println!("POST   /api/reindex            -> rebuild data/index.sqlite with Rust");
    println!("GET    /vault/**/*.md          -> read vault markdown");
    println!("PUT    /vault/**/*.md          -> update existing vault markdown");
    println!("POST   /vault/notes/**/*.md    -> create notes");
    println!("DELETE /vault/notes/**/*.md    -> soft-delete notes");
    axum::serve(tokio::net::TcpListener::bind(addr).await?, app).await?;
    Ok(())
}

async fn api_index(State(state): State<AppState>) -> Result<Json<serde_json::Value>, AppError> {
    let items = reader_core::load_entries(&state.paths)?;
    Ok(Json(
        json!({ "items": items, "generatedFrom": "rust-sqlite" }),
    ))
}

/// Cheap directory listing (path + mtime) — the file-browser's source of "what
/// exists", independent of the metadata cache. Clients diff this to find files
/// changed since the last index build.
async fn api_files(State(state): State<AppState>) -> Result<Json<serde_json::Value>, AppError> {
    let items = reader_core::list_vault_files(&state.paths)?;
    Ok(Json(json!({ "items": items })))
}

#[derive(Debug, Deserialize)]
struct EntryParams {
    path: String,
}

/// Live-parse ONE vault file's metadata straight from disk (no DB). `entry` is
/// null when the file is missing or has no usable type, so the client can skip
/// non-entries without thrashing.
async fn api_entry(
    State(state): State<AppState>,
    Query(params): Query<EntryParams>,
) -> Result<Json<serde_json::Value>, AppError> {
    let entry = reader_core::parse_entry(&state.paths, &params.path)?;
    Ok(Json(json!({ "entry": entry })))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SearchParams {
    q: String,
    #[serde(rename = "type")]
    entry_type: Option<String>,
    min_rating: Option<f64>,
    theme: Option<String>,
    limit: Option<usize>,
    /// "lex" (default) or "hybrid".
    #[serde(default)]
    mode: Option<String>,
}

async fn api_search(
    State(state): State<AppState>,
    Query(params): Query<SearchParams>,
) -> Result<Json<serde_json::Value>, AppError> {
    let paths = state.paths.clone();
    let model = state.model.clone();
    let mode = match params.mode.as_deref() {
        Some("hybrid") => reader_core::SearchMode::Hybrid,
        _ => reader_core::SearchMode::Lex,
    };
    let options = reader_core::SearchOptions {
        query: params.q,
        entry_type: params.entry_type,
        min_rating: params.min_rating,
        theme: params.theme,
        limit: params.limit.unwrap_or(80),
        mode,
    };
    let rt = tokio::runtime::Handle::current();
    let hits = tokio::task::spawn_blocking(move || {
        reader_core::search_entries(&paths, options, Some(&model), &rt)
    })
    .await
    .map_err(|err| AppError(ReaderError::Other(err.into())))??;
    Ok(Json(json!({ "items": hits })))
}

async fn api_reindex(State(state): State<AppState>) -> Result<Json<serde_json::Value>, AppError> {
    let _guard = match state.reindex_lock.try_lock() {
        Ok(g) => g,
        Err(_) => {
            return Err(AppError(ReaderError::Conflict(
                "reindex already in progress".to_string(),
            )))
        }
    };
    let t0 = Instant::now();
    let paths = state.paths.clone();
    let stats = tokio::task::spawn_blocking(move || reader_core::build_sqlite_index(&paths))
        .await
        .map_err(|err| AppError(ReaderError::Other(err.into())))??;
    Ok(Json(json!({
        "ok": true,
        "tookMs": t0.elapsed().as_millis(),
        "entries": stats.entries,
        "byType": stats.by_type,
        "sourcePdfs": stats.source_pdfs,
        "skippedFrontmatterWithoutType": stats.skipped_frontmatter_without_type
    })))
}

async fn api_trash_list(
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, AppError> {
    let items = reader_core::list_trash(&state.paths)?;
    Ok(Json(json!({ "items": items })))
}

async fn api_trash_restore(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<Json<serde_json::Value>, AppError> {
    let restored = reader_core::restore_trash(&state.paths, &name)?;
    Ok(Json(json!({ "ok": true, "restored": restored })))
}

async fn api_trash_purge(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<Json<serde_json::Value>, AppError> {
    reader_core::purge_trash(&state.paths, &name)?;
    Ok(Json(json!({ "ok": true })))
}

async fn get_vault_file(
    State(state): State<AppState>,
    Path(path): Path<String>,
) -> Result<Response, AppError> {
    serve_workspace_file(&state.paths, &format!("vault/{path}")).await
}

async fn get_source_file(
    State(state): State<AppState>,
    Path(path): Path<String>,
) -> Result<Response, AppError> {
    serve_workspace_file(&state.paths, &format!("sources/{path}")).await
}

async fn get_reader_data_file(
    State(state): State<AppState>,
    Path(path): Path<String>,
) -> Result<Response, AppError> {
    // Never serve the live SQLite index or its WAL/journal sidecars via raw
    // fs::read — that races concurrent incremental writes and can read a torn
    // file. Clients use /api/index, not the DB file.
    if path
        .rsplit('/')
        .next()
        .is_some_and(|name| name.starts_with("index.sqlite"))
    {
        return Err(AppError(ReaderError::Forbidden(
            "index database is not served directly".to_string(),
        )));
    }
    serve_workspace_file(&state.paths, &format!("reader/data/{path}")).await
}

async fn put_vault_file(
    State(state): State<AppState>,
    Path(path): Path<String>,
    body: Bytes,
) -> Result<Json<serde_json::Value>, AppError> {
    let mtime = reader_core::put_markdown(&state.paths, &format!("vault/{path}"), &body)?;
    Ok(Json(json!({
        "ok": true,
        "bytes": body.len(),
        "mtime": mtime
    })))
}

async fn post_vault_note(
    State(state): State<AppState>,
    Path(path): Path<String>,
    body: Bytes,
) -> Result<(StatusCode, Json<serde_json::Value>), AppError> {
    let (created_path, mtime) =
        reader_core::post_note(&state.paths, &format!("vault/{path}"), &body)?;
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "ok": true,
            "bytes": body.len(),
            "mtime": mtime,
            "path": created_path
        })),
    ))
}

async fn delete_vault_note(
    State(state): State<AppState>,
    Path(path): Path<String>,
) -> Result<Json<serde_json::Value>, AppError> {
    let trash = reader_core::delete_note(&state.paths, &format!("vault/{path}"))?;
    Ok(Json(json!({ "ok": true, "trash": trash })))
}

async fn get_reader_dist_root(State(state): State<AppState>) -> Result<Response, AppError> {
    let file = reader_core::reader_dist_file(&state.paths, "/reader/")?;
    serve_file(file).await
}

async fn get_reader_dist_file(
    State(state): State<AppState>,
    Path(path): Path<String>,
) -> Result<Response, AppError> {
    let file = reader_core::reader_dist_file(&state.paths, &format!("/reader/{path}"))?;
    serve_file(file).await
}

async fn serve_workspace_file(paths: &ReaderPaths, path: &str) -> Result<Response, AppError> {
    let file = reader_core::resolve_get_path(paths, path)?;
    serve_file(file).await
}

async fn serve_file(path: PathBuf) -> Result<Response, AppError> {
    let bytes = fs::read(&path)?;
    let mut response = Response::new(Body::from(bytes));
    let mime = mime_guess::from_path(&path).first_or_octet_stream();
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(mime.as_ref())
            .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream")),
    );
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    Ok(response)
}

struct AppError(ReaderError);

impl From<ReaderError> for AppError {
    fn from(value: ReaderError) -> Self {
        Self(value)
    }
}

impl From<anyhow::Error> for AppError {
    fn from(value: anyhow::Error) -> Self {
        Self(ReaderError::Other(value))
    }
}

impl From<std::io::Error> for AppError {
    fn from(value: std::io::Error) -> Self {
        Self(ReaderError::Other(value.into()))
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match self.0 {
            ReaderError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg),
            ReaderError::Forbidden(msg) => (StatusCode::FORBIDDEN, msg),
            ReaderError::NotFound(msg) => (StatusCode::NOT_FOUND, msg),
            ReaderError::Conflict(msg) => (StatusCode::CONFLICT, msg),
            ReaderError::Unsupported(msg) => (StatusCode::UNSUPPORTED_MEDIA_TYPE, msg),
            ReaderError::Io(err) => {
                eprintln!("[reader-api] {err:?}");
                (StatusCode::INTERNAL_SERVER_ERROR, err.to_string())
            }
            ReaderError::Sql(err) => {
                eprintln!("[reader-api] {err:?}");
                (StatusCode::INTERNAL_SERVER_ERROR, err.to_string())
            }
            ReaderError::Other(err) => {
                eprintln!("[reader-api] {err:?}");
                (StatusCode::INTERNAL_SERVER_ERROR, err.to_string())
            }
        };
        let mut response = (status, message).into_response();
        response.headers_mut().insert(
            header::ACCESS_CONTROL_ALLOW_ORIGIN,
            HeaderValue::from_static("*"),
        );
        response
    }
}
