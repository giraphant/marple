use std::{env, fs, net::SocketAddr, path::PathBuf, sync::Arc, time::Instant};

use axum::{
    body::{Body, Bytes},
    extract::{Path, Query, State},
    http::{header, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use notify_debouncer_mini::{
    new_debouncer,
    notify::{RecommendedWatcher, RecursiveMode},
    DebounceEventResult, Debouncer,
};
use reader_core::embed_job::{EmbedJob, EmbedOutcome};
use reader_core::{ReaderError, ReaderPaths};
use serde::Deserialize;
use serde_json::json;
use tower_http::cors::{Any, CorsLayer};

#[derive(Clone)]
struct AppState {
    paths: Arc<ReaderPaths>,
    model: reader_core::vector::ModelHandle,
    reindex_lock: Arc<tokio::sync::Mutex<()>>,
    /// Background semantic-vector build job. Decoupled from `reindex_lock`:
    /// embeddings write `vectors.sqlite`, reindex writes `index.sqlite`, so the
    /// two run concurrently. Single-flight is enforced by the job itself.
    embed_job: EmbedJob,
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
        embed_job: EmbedJob::new(),
    };

    maybe_auto_embed(&state);

    // Background index maintenance needs the paths after `state` is moved into
    // the router.
    let bg_paths = state.paths.clone();

    let app = Router::new()
        .route("/api/index", get(api_index))
        .route("/api/files", get(api_files))
        .route("/api/entry", get(api_entry))
        .route("/api/search", get(api_search))
        .route("/api/reindex", post(api_reindex))
        .route("/api/reconcile", post(api_reconcile))
        .route("/api/open-pdf", post(api_open_pdf))
        .route("/api/open-in-editor", post(api_open_in_editor))
        .route("/api/translations", get(api_translations))
        .route("/api/open-translation", post(api_open_translation))
        .route("/api/embeddings", post(api_embeddings))
        .route("/api/embeddings/status", get(api_embeddings_status))
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
    println!("POST   /api/reconcile          -> delta-sync index to the vault (cheap)");
    println!("POST   /api/open-pdf           -> open sources/<slug>.pdf in the system PDF app");
    println!("POST   /api/open-in-editor     -> open a vault/*.md in the chosen external editor");
    println!("POST   /api/embeddings         -> start background semantic-vector build (202)");
    println!("GET    /api/embeddings/status  -> poll embedding job + on-disk vectors summary");
    println!("GET    /vault/**/*.md          -> read vault markdown");
    println!("PUT    /vault/**/*.md          -> update existing vault markdown");
    println!("POST   /vault/notes/**/*.md    -> create notes");
    println!("DELETE /vault/notes/**/*.md    -> soft-delete notes");

    // Catch edits made while the server was down, then live-watch for new ones.
    spawn_boot_reconcile(bg_paths.clone());
    let _watcher = match start_vault_watcher(bg_paths.clone()) {
        Ok(watcher) => Some(watcher),
        Err(err) => {
            eprintln!("vault watcher disabled (search won't auto-refresh on external edits): {err}");
            None
        }
    };

    axum::serve(tokio::net::TcpListener::bind(addr).await?, app).await?;
    Ok(())
}

/// Reconcile once at startup so changes made while the server was down (git
/// pull, external edits) are reflected without a manual reindex. Fire-and-forget
/// on a blocking thread; the delta is cheap when little changed.
fn spawn_boot_reconcile(paths: Arc<ReaderPaths>) {
    tokio::task::spawn_blocking(move || match reader_core::reconcile_index(&paths) {
        Ok(s) => println!(
            "boot reconcile: upserted {}, removed {}, unchanged {}",
            s.upserted, s.removed, s.unchanged
        ),
        Err(e) => eprintln!("boot reconcile failed: {e}"),
    });
}

/// Watch the vault and run a debounced delta reconcile on any change. The
/// watcher only hints "something changed" — `reconcile_index` decides *what*
/// via mtime diff — so a dropped/missed event is self-healed by the next event
/// or the boot reconcile. Index writes land outside the vault dir, so this never
/// feeds back on itself. The returned Debouncer must be kept alive to keep
/// watching.
fn start_vault_watcher(paths: Arc<ReaderPaths>) -> anyhow::Result<Debouncer<RecommendedWatcher>> {
    let vault = paths.vault.clone();
    let mut debouncer = new_debouncer(
        std::time::Duration::from_millis(500),
        move |res: DebounceEventResult| match res {
            Ok(_events) => match reader_core::reconcile_index(&paths) {
                Ok(s) if s.upserted + s.removed > 0 => println!(
                    "watch reconcile: upserted {}, removed {}",
                    s.upserted, s.removed
                ),
                Ok(_) => {}
                Err(e) => eprintln!("watch reconcile failed: {e}"),
            },
            Err(e) => eprintln!("vault watch error: {e:?}"),
        },
    )?;
    debouncer.watcher().watch(&vault, RecursiveMode::Recursive)?;
    Ok(debouncer)
}

async fn api_index(State(state): State<AppState>) -> Result<Json<serde_json::Value>, AppError> {
    let items = reader_core::load_entries(&state.paths)?;
    Ok(Json(
        json!({ "items": items, "generatedFrom": "rust-sqlite" }),
    ))
}

#[derive(Debug, Deserialize)]
struct FilesParams {
    /// Epoch-ms cutoff: when set, only files with mtime > since are returned
    /// (the delta), so a no-op or small-edit sync ships almost nothing. `total`
    /// is always the full file count so the client can detect deletions.
    since: Option<i64>,
}

/// Cheap directory listing (path + mtime) — the file-browser's source of "what
/// exists", independent of the metadata cache. With `?since=` it returns only
/// the changed delta plus the total count.
async fn api_files(
    State(state): State<AppState>,
    Query(params): Query<FilesParams>,
) -> Result<Json<serde_json::Value>, AppError> {
    let all = reader_core::list_vault_files(&state.paths)?;
    let total = all.len();
    let items: Vec<_> = match params.since {
        Some(since) => all
            .into_iter()
            .filter(|f| f.mtime.is_none_or(|m| m > since))
            .collect(),
        None => all,
    };
    Ok(Json(json!({ "items": items, "total": total })))
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
    /// "fast" | "balanced" (default) | "deep".
    #[serde(default)]
    mode: Option<String>,
}

/// Map the `mode` query param to a search mode. "fast"/"deep" select those
/// modes; everything else — missing, unknown, or the retired "lex"/"hybrid"
/// aliases — falls back to the balanced default.
fn parse_search_mode(raw: Option<&str>) -> reader_core::SearchMode {
    match raw {
        Some("fast") => reader_core::SearchMode::Fast,
        Some("deep") => reader_core::SearchMode::Deep,
        _ => reader_core::SearchMode::Balanced,
    }
}

async fn api_search(
    State(state): State<AppState>,
    Query(params): Query<SearchParams>,
) -> Result<Json<serde_json::Value>, AppError> {
    let paths = state.paths.clone();
    let model = state.model.clone();
    let mode = parse_search_mode(params.mode.as_deref());
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
        "skippedFrontmatterWithoutType": stats.skipped_frontmatter_without_type,
        "skipped": serde_json::to_value(&stats.skipped).unwrap_or_default()
    })))
}

/// Cheap delta-sync: bring the index into agreement with the vault by diffing
/// per-file mtimes (new/changed/deleted), instead of the full /api/reindex
/// rebuild. Safe to call often.
async fn api_reconcile(State(state): State<AppState>) -> Result<Json<serde_json::Value>, AppError> {
    let paths = state.paths.clone();
    let stats = tokio::task::spawn_blocking(move || reader_core::reconcile_index(&paths))
        .await
        .map_err(|err| AppError(ReaderError::Other(err.into())))??;
    Ok(Json(json!({
        "ok": true,
        "upserted": stats.upserted,
        "removed": stats.removed,
        "unchanged": stats.unchanged,
    })))
}

#[derive(Debug, Deserialize)]
struct OpenPdfParams {
    slug: String,
}

/// Open a vault PDF with the host's default PDF application instead of the
/// browser (QUA-55). Resolves `sources/<slug>.pdf` under the sources tree, then
/// hands the absolute path to the OS opener as a single argument (no shell).
/// Runs on a blocking thread because the opener is invoked synchronously.
async fn api_open_pdf(
    State(state): State<AppState>,
    Json(params): Json<OpenPdfParams>,
) -> Result<Json<serde_json::Value>, AppError> {
    let paths = state.paths.clone();
    tokio::task::spawn_blocking(move || -> Result<(), ReaderError> {
        let path = reader_core::resolve_source_pdf(&paths, &params.slug)?;
        reader_core::open_in_system_app(&path)
    })
    .await
    .map_err(|err| AppError(ReaderError::Other(err.into())))??;
    Ok(Json(json!({ "ok": true })))
}

#[derive(Debug, Deserialize)]
struct OpenInEditorParams {
    /// Vault-relative path of the markdown file, e.g. `vault/notes/foo.md`.
    path: String,
    /// Editor app to open with. Empty / absent → the OS default `.md` handler.
    #[serde(default)]
    app: String,
}

/// Open a vault markdown file in the user's chosen external editor (QUA-72). The
/// browser can't launch native apps, so reader-api shells out — but never through
/// a shell: the app name and file path are passed as separate `Command` args, so
/// the user-supplied app string has no injection surface. Path is validated to
/// live under `vault/` and be an existing `.md`. Runs on a blocking thread.
async fn api_open_in_editor(
    State(state): State<AppState>,
    Json(params): Json<OpenInEditorParams>,
) -> Result<Json<serde_json::Value>, AppError> {
    let paths = state.paths.clone();
    tokio::task::spawn_blocking(move || -> Result<(), ReaderError> {
        reader_core::open_in_editor(&paths, &params.path, &params.app)
    })
    .await
    .map_err(|err| AppError(ReaderError::Other(err.into())))??;
    Ok(Json(json!({ "ok": true })))
}

/// List the slugs that have a translated PDF under `processing/translations/`.
/// Read live (cheap dir scan) so newly-added translations need no reindex.
async fn api_translations(State(state): State<AppState>) -> Json<serde_json::Value> {
    let slugs = reader_core::list_translation_slugs(&state.paths);
    Json(json!(slugs))
}

/// Open a translated PDF (`processing/translations/<slug>-zh.pdf`) in the host's
/// default PDF app. Mirrors `api_open_pdf` (same untrusted-slug discipline).
async fn api_open_translation(
    State(state): State<AppState>,
    Json(params): Json<OpenPdfParams>,
) -> Result<Json<serde_json::Value>, AppError> {
    let paths = state.paths.clone();
    tokio::task::spawn_blocking(move || -> Result<(), ReaderError> {
        let path = reader_core::resolve_translation_pdf(&paths, &params.slug)?;
        reader_core::open_in_system_app(&path)
    })
    .await
    .map_err(|err| AppError(ReaderError::Other(err.into())))??;
    Ok(Json(json!({ "ok": true })))
}

/// Opt-in, heavy: (re)build the semantic vector embeddings. Loads the ~2.3 GB
/// BGE-M3 model. Returns immediately — the build runs as a detached background
/// job; clients poll `GET /api/embeddings/status`. Decoupled from `reindex_lock`
/// (writes a separate `vectors.sqlite`), so a metadata reindex is never blocked.
async fn api_embeddings(
    State(state): State<AppState>,
) -> (StatusCode, Json<serde_json::Value>) {
    if !state.embed_job.try_begin() {
        // Already building → tell the client to just poll status.
        return (
            StatusCode::CONFLICT,
            Json(embed_status_json(&state.paths, &state.embed_job)),
        );
    }
    spawn_embed_job(state.paths.clone(), state.embed_job.clone());
    (
        StatusCode::ACCEPTED,
        Json(embed_status_json(&state.paths, &state.embed_job)),
    )
}

/// Current embedding job state + the truthful on-disk vectors summary (count /
/// model / completed-at), so the UI shows "already built (N)" even after a
/// restart cleared the in-memory job back to idle.
async fn api_embeddings_status(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(embed_status_json(&state.paths, &state.embed_job))
}

/// Run the embedding build on a detached background task. Every join outcome —
/// success, build error, or panic/cancel — drives the job to a terminal state,
/// so a panic can never wedge it permanently at `Running` (which would 409 every
/// later trigger until restart).
fn spawn_embed_job(paths: Arc<ReaderPaths>, job: EmbedJob) {
    tokio::spawn(async move {
        let progress_job = job.clone();
        let build_paths = paths.clone();
        let outcome = tokio::task::spawn_blocking(move || {
            reader_core::build_embeddings_with_progress(&build_paths, &|done, total| {
                progress_job.set_total(total);
                progress_job.set_embedded(done);
            })
        })
        .await;
        match outcome {
            Ok(Ok(n)) => job.settle(EmbedOutcome::Ok(n)),
            Ok(Err(err)) => job.settle(EmbedOutcome::BuildError(err.to_string())),
            Err(join) => job.settle(EmbedOutcome::Panicked(format!("embed task panicked: {join}"))),
        }
    });
}

/// Boot gate for the background auto-embed: only when vectors are missing, an
/// index exists to embed from, the model is already cached (no surprise 2.3 GB
/// download), and the env opt-out is not set.
fn should_auto_embed(
    vectors_exist: bool,
    index_exists: bool,
    model_ready: bool,
    env_disabled: bool,
) -> bool {
    !env_disabled && index_exists && model_ready && !vectors_exist
}

/// Kick off the background embedding build on startup when the gate allows it.
/// Detached, so it never blocks the server from coming up.
fn maybe_auto_embed(state: &AppState) {
    let env_disabled = matches!(
        env::var("READER_AUTO_EMBED").ok().as_deref(),
        Some("0") | Some("false") | Some("off")
    );
    let vectors_exist = state.paths.vectors_db.is_file();
    let index_exists = state.paths.index_db.is_file();
    let model_ready = reader_core::model_cache_ready(&state.paths);

    if should_auto_embed(vectors_exist, index_exists, model_ready, env_disabled) {
        if state.embed_job.try_begin() {
            println!("auto-embed: vectors missing + model cached -> building in background");
            spawn_embed_job(state.paths.clone(), state.embed_job.clone());
        }
    } else if !vectors_exist && index_exists && !model_ready && !env_disabled {
        println!(
            "auto-embed skipped: BGE-M3 not cached yet — click 重建语义向量 once to download it"
        );
    }
}

/// Compose the embedding-status DTO from the in-memory job snapshot and the
/// on-disk vectors summary. camelCase keys for the frontend.
fn embed_status_json(paths: &ReaderPaths, job: &EmbedJob) -> serde_json::Value {
    let s = job.snapshot();
    let summary = reader_core::vectors_summary(paths);
    let phase = match s.phase {
        reader_core::embed_job::EmbedPhase::Idle => "idle",
        reader_core::embed_job::EmbedPhase::Running => "running",
        reader_core::embed_job::EmbedPhase::Done => "done",
        reader_core::embed_job::EmbedPhase::Failed => "failed",
    };
    // Prefer the persisted completion time (survives restart) over the job's.
    let completed_at = summary
        .as_ref()
        .and_then(|v| v.completed_at.clone())
        .or(s.completed_at);
    json!({
        "phase": phase,
        "embedded": s.embedded,
        "total": s.total,
        "vectorsExist": summary.is_some(),
        "vectorsCount": summary.as_ref().map(|v| v.count),
        "model": summary.as_ref().and_then(|v| v.model.clone()),
        "completedAt": completed_at,
        "startedAt": s.started_at,
        "error": s.error,
    })
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
        .is_some_and(|name| name.starts_with("index.sqlite") || name.starts_with("vectors.sqlite"))
    {
        return Err(AppError(ReaderError::Forbidden(
            "database files are not served directly".to_string(),
        )));
    }
    serve_workspace_file(&state.paths, &format!("reader/data/{path}")).await
}

async fn put_vault_file(
    State(state): State<AppState>,
    Path(path): Path<String>,
    body: Bytes,
) -> Result<Json<serde_json::Value>, AppError> {
    let rel = format!("vault/{path}");
    let mtime = reader_core::put_markdown(&state.paths, &rel, &body)?;
    // Update the index immediately for this one file (best-effort: the watcher /
    // boot reconcile would catch it anyway, but this makes the edit searchable
    // without the debounce wait).
    if let Err(e) = reader_core::upsert_entry(&state.paths, &rel) {
        eprintln!("index upsert failed for {rel}: {e}");
    }
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
    if let Err(e) = reader_core::upsert_entry(&state.paths, &created_path) {
        eprintln!("index upsert failed for {created_path}: {e}");
    }
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
    let rel = format!("vault/{path}");
    let trash = reader_core::delete_note(&state.paths, &rel)?;
    if let Err(e) = reader_core::remove_entry(&state.paths, &rel) {
        eprintln!("index remove failed for {rel}: {e}");
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use reader_core::embed_job::EmbedJob;

    fn tmp_paths() -> ReaderPaths {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("reader-api-test-{nonce}"));
        let reader_root = root.join("reader");
        let vault = root.join("vault");
        std::fs::create_dir_all(reader_root.join("data")).unwrap();
        std::fs::create_dir_all(vault.join("notes/.trash")).unwrap();
        ReaderPaths {
            reader_root: reader_root.clone(),
            workspace_root: root.clone(),
            vault: vault.clone(),
            notes_dir: vault.join("notes"),
            trash_dir: vault.join("notes/.trash"),
            sources: root.join("sources"),
            translations: root.join("processing/translations"),
            index_db: reader_root.join("data/index.sqlite"),
            vectors_db: reader_root.join("data/vectors.sqlite"),
            dist: reader_root.join("dist"),
        }
    }

    #[test]
    fn search_mode_parsing() {
        use reader_core::SearchMode;
        assert_eq!(parse_search_mode(Some("fast")), SearchMode::Fast);
        assert_eq!(parse_search_mode(Some("balanced")), SearchMode::Balanced);
        assert_eq!(parse_search_mode(Some("deep")), SearchMode::Deep);
        // Missing, unknown, and the retired lex/hybrid aliases all fall back to
        // the balanced default.
        assert_eq!(parse_search_mode(None), SearchMode::Balanced);
        assert_eq!(parse_search_mode(Some("lex")), SearchMode::Balanced);
        assert_eq!(parse_search_mode(Some("hybrid")), SearchMode::Balanced);
        assert_eq!(parse_search_mode(Some("garbage")), SearchMode::Balanced);
    }

    #[test]
    fn auto_embed_only_when_missing_indexed_cached_and_enabled() {
        // The happy path: vectors missing, index present, model cached, not disabled.
        assert!(should_auto_embed(false, true, true, false));
        // Any single blocker turns it off.
        assert!(!should_auto_embed(true, true, true, false), "vectors already exist");
        assert!(!should_auto_embed(false, false, true, false), "no index to embed from");
        assert!(!should_auto_embed(false, true, false, false), "model not cached → no surprise download");
        assert!(!should_auto_embed(false, true, true, true), "disabled by env");
    }

    #[test]
    fn status_json_when_no_vectors_and_idle() {
        let paths = tmp_paths();
        let job = EmbedJob::new();
        let v = embed_status_json(&paths, &job);
        assert_eq!(v["phase"], "idle");
        assert_eq!(v["vectorsExist"], false);
        assert!(v["vectorsCount"].is_null());
        assert!(v["model"].is_null());
        assert_eq!(v["embedded"], 0);
        assert_eq!(v["total"], 0);
    }

    #[test]
    fn status_json_reports_real_vectors_count_after_build() {
        let paths = tmp_paths();
        // Placeholder index so build_embeddings proceeds; empty vault → 0 vectors,
        // no model download.
        std::fs::write(&paths.index_db, b"placeholder").unwrap();
        reader_core::build_embeddings_with_progress(&paths, &|_, _| {}).unwrap();

        let job = EmbedJob::new();
        let v = embed_status_json(&paths, &job);
        assert_eq!(v["vectorsExist"], true);
        assert_eq!(v["vectorsCount"], 0);
        assert_eq!(v["model"], "BAAI/bge-m3");
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
