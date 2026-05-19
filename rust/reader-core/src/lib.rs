use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use chrono::Utc;
use rusqlite::{Connection, OpenFlags, Row};
use serde::Serialize;
use serde_json::Value;
use thiserror::Error;

mod indexer;
pub mod fuse;

pub use indexer::{build_sqlite_index, IndexStats};

use std::sync::Once;
static SQLITE_VEC_INIT: Once = Once::new();

/// Register the sqlite-vec extension with SQLite once per process.
///
/// `sqlite3_auto_extension` is global; every Connection opened after this
/// call automatically has the vec0 virtual-table module and vec_*() SQL
/// functions available. Safe to call from multiple call sites; only the
/// first call has effect.
pub fn init_sqlite_vec() {
    SQLITE_VEC_INIT.call_once(|| unsafe {
        rusqlite::ffi::sqlite3_auto_extension(Some(std::mem::transmute(
            sqlite_vec::sqlite3_vec_init as *const (),
        )));
    });
}

const TRASH_TS_SUFFIX_LEN: usize = ".0000-00-00T00-00-00-000Z.md".len();

#[derive(Clone, Debug)]
pub struct ReaderPaths {
    pub reader_root: PathBuf,
    pub workspace_root: PathBuf,
    pub vault: PathBuf,
    pub notes_dir: PathBuf,
    pub trash_dir: PathBuf,
    pub sources: PathBuf,
    pub index_db: PathBuf,
    pub dist: PathBuf,
}

impl ReaderPaths {
    pub fn from_reader_root(reader_root: impl Into<PathBuf>) -> Result<Self> {
        let reader_root = reader_root.into().canonicalize().with_context(|| {
            "failed to resolve reader root; run from reader/ or set READER_ROOT"
        })?;
        let workspace_root = reader_root
            .parent()
            .context("reader root has no parent workspace")?
            .to_path_buf();
        let vault = workspace_root.join("vault");
        let notes_dir = vault.join("notes");
        Ok(Self {
            index_db: reader_root.join("data").join("index.sqlite"),
            trash_dir: notes_dir.join(".trash"),
            sources: workspace_root.join("sources"),
            dist: reader_root.join("dist"),
            reader_root,
            workspace_root,
            vault,
            notes_dir,
        })
    }
}

#[derive(Debug, Error)]
pub enum ReaderError {
    #[error("{0}")]
    BadRequest(String),
    #[error("{0}")]
    Forbidden(String),
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Conflict(String),
    #[error("{0}")]
    Unsupported(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Sql(#[from] rusqlite::Error),
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

pub type ReaderResult<T> = std::result::Result<T, ReaderError>;

#[derive(Clone, Debug, Serialize)]
pub struct Entry {
    pub path: String,
    #[serde(rename = "type")]
    pub entry_type: String,
    pub book: Option<String>,
    pub title: Option<String>,
    pub author: Option<String>,
    pub year: Option<Value>,
    pub rating: Option<Value>,
    pub rating_score: f64,
    pub themes: Option<Vec<String>>,
    pub topic: Option<String>,
    pub source: Option<String>,
    pub doi: Option<String>,
    pub chapters_analyzed: Option<i64>,
    pub annotates: Option<String>,
    pub created: Option<String>,
    pub has_pdf: bool,
    pub pdf_slug: Option<String>,
    pub mtime: Option<i64>,
    pub preview: String,
}

#[derive(Debug, Serialize)]
pub struct TrashItem {
    pub name: String,
    #[serde(rename = "originalBase")]
    pub original_base: Option<String>,
    pub ts: Option<String>,
    pub mtime: f64,
    pub size: u64,
}

#[derive(Debug, Clone)]
pub struct SearchOptions {
    pub query: String,
    pub entry_type: Option<String>,
    pub min_rating: Option<f64>,
    pub theme: Option<String>,
    pub limit: usize,
}

#[derive(Debug, Serialize)]
pub struct SearchHit {
    pub entry: Entry,
    pub score: f64,
    pub snippet: Option<String>,
    pub source: String,
}

pub fn load_entries(paths: &ReaderPaths) -> ReaderResult<Vec<Entry>> {
    if !paths.index_db.is_file() {
        return Err(ReaderError::NotFound(
            "index database missing; run npm run build:index in reader/".to_string(),
        ));
    }

    let conn = Connection::open_with_flags(&paths.index_db, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("failed to open {}", paths.index_db.display()))?;

    let mut stmt = conn.prepare(
        r#"
        SELECT
          path, type, book, title, author, year_json, rating_json, rating_score,
          themes_json, topic, source, doi, chapters_analyzed, annotates, created,
          pdf_slug, has_pdf, mtime, preview
        FROM entries
        ORDER BY
          type,
          rating_score DESC,
          lower(coalesce(title, path)),
          coalesce(title, path)
        "#,
    )?;
    let entries = stmt
        .query_map([], row_to_entry)?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(entries)
}

pub fn search_entries(paths: &ReaderPaths, options: SearchOptions) -> ReaderResult<Vec<SearchHit>> {
    if !paths.index_db.is_file() {
        return Err(ReaderError::NotFound(
            "index database missing; run npm run build:index in reader/".to_string(),
        ));
    }

    let query = options.query.trim();
    if query.is_empty() {
        return Ok(Vec::new());
    }

    let limit = options.limit.clamp(1, 500);
    let conn = Connection::open_with_flags(&paths.index_db, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("failed to open {}", paths.index_db.display()))?;
    let mut candidates: HashMap<String, SearchCandidate> = HashMap::new();
    let tokens = query_terms(query);

    if query.chars().filter(|c| !c.is_whitespace()).count() >= 2 {
        let phrase = quote_fts(query);
        collect_fts_candidates(&conn, &phrase, limit * 4, 4.0, "phrase", &mut candidates)?;
    }

    if !tokens.is_empty() {
        let all_terms = tokens
            .iter()
            .map(|token| quote_fts(token))
            .collect::<Vec<_>>()
            .join(" AND ");
        collect_fts_candidates(&conn, &all_terms, limit * 5, 2.5, "fulltext", &mut candidates)?;

        if tokens.len() > 1 {
            let any_terms = tokens
                .iter()
                .map(|token| quote_fts(token))
                .collect::<Vec<_>>()
                .join(" OR ");
            collect_fts_candidates(&conn, &any_terms, limit * 6, 1.2, "expanded", &mut candidates)?;
        }
    }

    let trigram_query = tokens
        .iter()
        .filter(|token| token.chars().count() >= 3)
        .map(|token| quote_fts(token))
        .collect::<Vec<_>>()
        .join(" OR ");
    if !trigram_query.is_empty() {
        collect_trigram_candidates(
            &conn,
            &trigram_query,
            limit * 4,
            0.9,
            "fuzzy",
            &mut candidates,
        )?;
    }

    if candidates.len() < limit
        && should_run_substring_fallback(query, &tokens, candidates.is_empty())
    {
        collect_substring_candidates(&conn, query, limit * 2, 0.45, &mut candidates)?;
    }

    let entries = load_entries(paths)?;
    let entries_by_path = entries
        .into_iter()
        .map(|entry| (entry.path.clone(), entry))
        .collect::<HashMap<_, _>>();

    let mut hits = candidates
        .into_values()
        .filter_map(|candidate| {
            let entry = entries_by_path.get(&candidate.path)?;
            if let Some(entry_type) = options.entry_type.as_deref() {
                if entry.entry_type != entry_type {
                    return None;
                }
            }
            if let Some(min_rating) = options.min_rating {
                if entry.rating_score < min_rating {
                    return None;
                }
            }
            if let Some(theme) = options.theme.as_deref() {
                if !entry
                    .themes
                    .as_ref()
                    .map(|themes| themes.iter().any(|item| item == theme))
                    .unwrap_or(false)
                {
                    return None;
                }
            }

            let mut entry = entry.clone();
            if let Some(snippet) = candidate.snippet.as_deref().map(clean_snippet) {
                if !snippet.is_empty() {
                    entry.preview = snippet;
                }
            }

            Some(SearchHit {
                score: candidate.score + entry.rating_score * 0.03,
                snippet: candidate.snippet,
                source: candidate.source,
                entry,
            })
        })
        .collect::<Vec<_>>();

    hits.sort_by(|a, b| {
        b.score
            .total_cmp(&a.score)
            .then_with(|| b.entry.rating_score.total_cmp(&a.entry.rating_score))
            .then_with(|| {
                a.entry
                    .title
                    .as_deref()
                    .unwrap_or(&a.entry.path)
                    .cmp(b.entry.title.as_deref().unwrap_or(&b.entry.path))
            })
    });
    hits.truncate(limit);
    Ok(hits)
}

#[derive(Debug)]
struct SearchCandidate {
    path: String,
    score: f64,
    snippet: Option<String>,
    source: String,
}

fn merge_candidate(
    candidates: &mut HashMap<String, SearchCandidate>,
    path: String,
    score: f64,
    snippet: Option<String>,
    source: &str,
) {
    match candidates.get_mut(&path) {
        Some(existing) => {
            let replaces_best = score > existing.score;
            existing.score += score;
            if snippet.as_deref().map(str::trim).is_some_and(|s| !s.is_empty())
                && (existing.snippet.is_none() || replaces_best)
            {
                existing.snippet = snippet;
            }
            if replaces_best {
                existing.source = source.to_string();
            }
        }
        None => {
            candidates.insert(
                path.clone(),
                SearchCandidate {
                    path,
                    score,
                    snippet,
                    source: source.to_string(),
                },
            );
        }
    }
}

fn collect_fts_candidates(
    conn: &Connection,
    fts_query: &str,
    limit: usize,
    multiplier: f64,
    source: &str,
    candidates: &mut HashMap<String, SearchCandidate>,
) -> ReaderResult<()> {
    let mut stmt = conn.prepare(
        r#"
        SELECT
          path,
          bm25(entry_search, 0.0, 0.0, 8.0, 5.0, 4.0, 3.0, 3.0, 2.5, 1.0, 2.0, 2.0, 1.0) AS rank,
          snippet(entry_search, -1, '', '', ' ... ', 28) AS snippet
        FROM entry_search
        WHERE entry_search MATCH ?
        ORDER BY rank
        LIMIT ?
        "#,
    )?;
    let rows = stmt.query_map((fts_query, limit as i64), |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, f64>(1)?,
            row.get::<_, Option<String>>(2)?,
        ))
    })?;

    for row in rows {
        let (path, rank, snippet) = row?;
        merge_candidate(candidates, path, (0.0 - rank) * multiplier, snippet, source);
    }
    Ok(())
}

fn collect_trigram_candidates(
    conn: &Connection,
    fts_query: &str,
    limit: usize,
    multiplier: f64,
    source: &str,
    candidates: &mut HashMap<String, SearchCandidate>,
) -> ReaderResult<()> {
    let mut stmt = conn.prepare(
        r#"
        SELECT
          path,
          bm25(entry_trigram) AS rank,
          snippet(entry_trigram, 2, '', '', ' ... ', 28) AS snippet
        FROM entry_trigram
        WHERE entry_trigram MATCH ?
        ORDER BY rank
        LIMIT ?
        "#,
    )?;
    let rows = stmt.query_map((fts_query, limit as i64), |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, f64>(1)?,
            row.get::<_, Option<String>>(2)?,
        ))
    })?;

    for row in rows {
        let (path, rank, snippet) = row?;
        merge_candidate(candidates, path, (0.0 - rank) * multiplier, snippet, source);
    }
    Ok(())
}

fn collect_substring_candidates(
    conn: &Connection,
    query: &str,
    limit: usize,
    multiplier: f64,
    candidates: &mut HashMap<String, SearchCandidate>,
) -> ReaderResult<()> {
    let needle = query.trim().to_lowercase();
    if needle.chars().filter(|c| !c.is_whitespace()).count() < 2 {
        return Ok(());
    }

    let mut stmt = conn.prepare(
        r#"
        SELECT path, search_text
        FROM entry_text
        WHERE instr(lower(search_text), ?) > 0
        LIMIT ?
        "#,
    )?;
    let rows = stmt.query_map((&needle, limit as i64), |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;

    for row in rows {
        let (path, text) = row?;
        let snippet = substring_snippet(&text, &needle);
        merge_candidate(candidates, path, multiplier, snippet, "substring");
    }
    Ok(())
}

fn query_terms(query: &str) -> Vec<String> {
    let mut terms = Vec::new();
    let mut current = String::new();
    for ch in query.chars() {
        if ch.is_alphanumeric() {
            current.extend(ch.to_lowercase());
        } else if !current.is_empty() {
            terms.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        terms.push(current);
    }
    terms.sort();
    terms.dedup();
    terms
        .into_iter()
        .filter(|term| term.chars().count() >= 2)
        .take(12)
        .collect()
}

fn should_run_substring_fallback(query: &str, tokens: &[String], no_fts_hits: bool) -> bool {
    if query.chars().count() > 80 {
        return false;
    }
    no_fts_hits || !query.is_ascii() || tokens.iter().any(|token| token.chars().count() < 3)
}

fn quote_fts(input: &str) -> String {
    format!("\"{}\"", input.replace('"', "\"\""))
}

fn clean_snippet(input: &str) -> String {
    input.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn substring_snippet(text: &str, needle: &str) -> Option<String> {
    let pos = find_case_insensitive(text, needle)?;
    let start = text[..pos]
        .char_indices()
        .rev()
        .nth(80)
        .map(|(idx, _)| idx)
        .unwrap_or(0);
    let end = text[pos..]
        .char_indices()
        .nth(160)
        .map(|(idx, _)| pos + idx)
        .unwrap_or(text.len());
    Some(clean_snippet(&text[start..end]))
}

fn find_case_insensitive(text: &str, needle: &str) -> Option<usize> {
    let needle = needle.to_lowercase();
    for (idx, _) in text.char_indices() {
        if text[idx..].to_lowercase().starts_with(&needle) {
            return Some(idx);
        }
    }
    None
}

pub fn list_trash(paths: &ReaderPaths) -> ReaderResult<Vec<TrashItem>> {
    if !paths.trash_dir.is_dir() {
        return Ok(Vec::new());
    }

    let mut items = Vec::new();
    for entry in fs::read_dir(&paths.trash_dir)
        .with_context(|| format!("failed to read {}", paths.trash_dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("md") {
            continue;
        }
        let meta = entry.metadata()?;
        if !meta.is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        items.push(TrashItem {
            original_base: trash_original_base(&name),
            ts: trash_ts(&name),
            mtime: meta
                .modified()
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs_f64() * 1000.0)
                .unwrap_or_default(),
            size: meta.len(),
            name,
        });
    }
    items.sort_by(|a, b| b.mtime.total_cmp(&a.mtime));
    Ok(items)
}

pub fn restore_trash(paths: &ReaderPaths, name: &str) -> ReaderResult<String> {
    let source = trash_item_path(paths, name)?;
    if !source.is_file() {
        return Err(ReaderError::NotFound("trash item not found".to_string()));
    }
    let base = trash_original_base(name).ok_or_else(|| {
        ReaderError::BadRequest("cannot determine original base name".to_string())
    })?;
    let target = paths.notes_dir.join(format!("{base}.md"));
    if target.exists() {
        return Err(ReaderError::Conflict(format!(
            "restore target already exists: {base}.md"
        )));
    }
    fs::rename(&source, &target)?;
    Ok(relative_slash(&paths.workspace_root, &target))
}

pub fn purge_trash(paths: &ReaderPaths, name: &str) -> ReaderResult<()> {
    let target = trash_item_path(paths, name)?;
    if !target.is_file() {
        return Err(ReaderError::NotFound("trash item not found".to_string()));
    }
    fs::remove_file(target)?;
    Ok(())
}

pub fn resolve_get_path(paths: &ReaderPaths, url_path: &str) -> ReaderResult<PathBuf> {
    let path = safe_join(&paths.workspace_root, url_path.trim_start_matches('/'))?;
    if !path.is_file() {
        return Err(ReaderError::NotFound("not found".to_string()));
    }
    Ok(path)
}

pub fn put_markdown(paths: &ReaderPaths, url_path: &str, body: &[u8]) -> ReaderResult<f64> {
    if body.len() > 5 * 1024 * 1024 {
        return Err(ReaderError::BadRequest("payload too large".to_string()));
    }
    let target = safe_join(&paths.workspace_root, url_path.trim_start_matches('/'))?;
    ensure_markdown(&target)?;
    ensure_under(&target, &paths.vault, "PUT only allowed under /vault/")?;
    if !target.is_file() {
        return Err(ReaderError::NotFound(
            "target file does not exist".to_string(),
        ));
    }
    ensure_frontmatter(body)?;
    atomic_write(&target, body)?;
    Ok(mtime_ms(&target)?)
}

pub fn post_note(paths: &ReaderPaths, url_path: &str, body: &[u8]) -> ReaderResult<(String, f64)> {
    if body.len() > 5 * 1024 * 1024 {
        return Err(ReaderError::BadRequest("payload too large".to_string()));
    }
    let target = safe_join(&paths.workspace_root, url_path.trim_start_matches('/'))?;
    ensure_markdown(&target)?;
    ensure_under(
        &target,
        &paths.notes_dir,
        "POST only allowed under /vault/notes/",
    )?;
    if target.exists() {
        return Err(ReaderError::Conflict(
            "file already exists; use PUT to update".to_string(),
        ));
    }
    ensure_frontmatter(body)?;
    atomic_write(&target, body)?;
    let rel = relative_slash(&paths.workspace_root, &target);
    Ok((rel, mtime_ms(&target)?))
}

pub fn delete_note(paths: &ReaderPaths, url_path: &str) -> ReaderResult<String> {
    let target = safe_join(&paths.workspace_root, url_path.trim_start_matches('/'))?;
    ensure_markdown(&target)?;
    ensure_under(
        &target,
        &paths.notes_dir,
        "DELETE only allowed under /vault/notes/",
    )?;
    if !target.is_file() {
        return Err(ReaderError::NotFound(
            "target file does not exist".to_string(),
        ));
    }
    fs::create_dir_all(&paths.trash_dir)?;
    let base = target
        .file_stem()
        .and_then(|s| s.to_str())
        .ok_or_else(|| ReaderError::BadRequest("invalid note filename".to_string()))?;
    let ts = Utc::now().format("%Y-%m-%dT%H-%M-%S-%3fZ").to_string();
    let trash_path = paths.trash_dir.join(format!("{base}.{ts}.md"));
    fs::rename(&target, &trash_path)?;
    Ok(relative_slash(&paths.workspace_root, &trash_path))
}

pub fn reader_dist_file(paths: &ReaderPaths, route_path: &str) -> ReaderResult<PathBuf> {
    let rel = route_path
        .trim_start_matches("/reader")
        .trim_start_matches('/');
    let candidate = if rel.is_empty() {
        paths.dist.join("index.html")
    } else {
        safe_join(&paths.dist, rel)?
    };
    if candidate.is_file() {
        return Ok(candidate);
    }
    let index = paths.dist.join("index.html");
    if index.is_file() {
        return Ok(index);
    }
    Err(ReaderError::NotFound(
        "dist missing; run npm run build in reader/".to_string(),
    ))
}

fn row_to_entry(row: &Row<'_>) -> rusqlite::Result<Entry> {
    let year_json: Option<String> = row.get(5)?;
    let rating_json: Option<String> = row.get(6)?;
    let themes_json: Option<String> = row.get(8)?;
    Ok(Entry {
        path: row.get(0)?,
        entry_type: row.get(1)?,
        book: row.get(2)?,
        title: row.get(3)?,
        author: row.get(4)?,
        year: parse_json_cell(year_json),
        rating: parse_json_cell(rating_json),
        rating_score: row.get::<_, Option<f64>>(7)?.unwrap_or_default(),
        themes: parse_json_cell(themes_json),
        topic: row.get(9)?,
        source: row.get(10)?,
        doi: row.get(11)?,
        chapters_analyzed: row.get(12)?,
        annotates: row.get(13)?,
        created: row.get(14)?,
        pdf_slug: row.get(15)?,
        has_pdf: row.get::<_, i64>(16)? != 0,
        mtime: row.get(17)?,
        preview: row.get::<_, Option<String>>(18)?.unwrap_or_default(),
    })
}

fn parse_json_cell<T: serde::de::DeserializeOwned>(raw: Option<String>) -> Option<T> {
    raw.and_then(|s| serde_json::from_str(&s).ok())
}

fn trash_item_path(paths: &ReaderPaths, name: &str) -> ReaderResult<PathBuf> {
    if name.is_empty() || name.starts_with('.') || name.contains('/') || name.contains('\\') {
        return Err(ReaderError::Forbidden("invalid trash name".to_string()));
    }
    if !name.ends_with(".md") {
        return Err(ReaderError::Forbidden("invalid trash name".to_string()));
    }
    safe_join(&paths.trash_dir, name)
}

fn trash_original_base(name: &str) -> Option<String> {
    if name.len() <= TRASH_TS_SUFFIX_LEN {
        return None;
    }
    let base_len = name.len() - TRASH_TS_SUFFIX_LEN;
    let suffix = &name[base_len..];
    if suffix_matches_trash_ts(suffix) {
        Some(name[..base_len].to_string())
    } else {
        None
    }
}

fn trash_ts(name: &str) -> Option<String> {
    if name.len() <= TRASH_TS_SUFFIX_LEN {
        return None;
    }
    let base_len = name.len() - TRASH_TS_SUFFIX_LEN;
    let suffix = &name[base_len + 1..name.len() - 3];
    if suffix_matches_trash_ts(&name[base_len..]) {
        Some(suffix.to_string())
    } else {
        None
    }
}

fn suffix_matches_trash_ts(suffix: &str) -> bool {
    let bytes = suffix.as_bytes();
    suffix.len() == TRASH_TS_SUFFIX_LEN
        && bytes.first() == Some(&b'.')
        && suffix.ends_with("Z.md")
        && bytes.get(5) == Some(&b'-')
        && bytes.get(8) == Some(&b'-')
        && bytes.get(11) == Some(&b'T')
        && bytes.get(14) == Some(&b'-')
        && bytes.get(17) == Some(&b'-')
        && bytes.get(20) == Some(&b'-')
}

fn safe_join(root: &Path, rel: &str) -> ReaderResult<PathBuf> {
    let root = root
        .canonicalize()
        .with_context(|| format!("failed to resolve {}", root.display()))?;
    let joined = root.join(rel);
    let parent = if joined.exists() {
        joined
            .canonicalize()
            .with_context(|| format!("failed to resolve {}", joined.display()))?
    } else {
        let parent = joined
            .parent()
            .ok_or_else(|| ReaderError::Forbidden("invalid path".to_string()))?;
        let parent = parent
            .canonicalize()
            .with_context(|| format!("failed to resolve {}", parent.display()))?;
        parent.join(joined.file_name().unwrap_or_default())
    };
    ensure_under(&parent, &root, "forbidden")?;
    Ok(parent)
}

fn ensure_under(path: &Path, root: &Path, msg: &str) -> ReaderResult<()> {
    let root = root
        .canonicalize()
        .with_context(|| format!("failed to resolve {}", root.display()))?;
    let check = if path.exists() {
        path.canonicalize()
            .with_context(|| format!("failed to resolve {}", path.display()))?
    } else {
        let parent = path
            .parent()
            .ok_or_else(|| ReaderError::Forbidden(msg.to_string()))?
            .canonicalize()
            .with_context(|| format!("failed to resolve parent of {}", path.display()))?;
        parent.join(path.file_name().unwrap_or_default())
    };
    if check == root || check.starts_with(&root) {
        Ok(())
    } else {
        Err(ReaderError::Forbidden(msg.to_string()))
    }
}

fn ensure_markdown(path: &Path) -> ReaderResult<()> {
    if path.extension().and_then(|ext| ext.to_str()) == Some("md") {
        Ok(())
    } else {
        Err(ReaderError::Unsupported(
            "only .md files allowed".to_string(),
        ))
    }
}

fn ensure_frontmatter(body: &[u8]) -> ReaderResult<()> {
    if body.starts_with(b"---\n") || body.starts_with(b"---\r") {
        Ok(())
    } else {
        Err(ReaderError::BadRequest(
            "body must start with --- frontmatter fence".to_string(),
        ))
    }
}

fn atomic_write(target: &Path, body: &[u8]) -> ReaderResult<()> {
    let dir = target
        .parent()
        .ok_or_else(|| ReaderError::BadRequest("invalid target path".to_string()))?;
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(
        ".{}.{}.tmp",
        target
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("write"),
        Utc::now().timestamp_nanos_opt().unwrap_or_default()
    ));
    fs::write(&tmp, body)?;
    fs::rename(tmp, target)?;
    Ok(())
}

fn mtime_ms(path: &Path) -> ReaderResult<f64> {
    let mtime = fs::metadata(path)?
        .modified()
        .map_err(|_| ReaderError::BadRequest("missing mtime".to_string()))?
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| ReaderError::BadRequest("mtime before epoch".to_string()))?;
    Ok(mtime.as_secs_f64() * 1000.0)
}

fn relative_slash(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .components()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}
