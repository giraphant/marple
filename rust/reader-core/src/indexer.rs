use std::{
    collections::{BTreeMap, HashSet},
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
    time::UNIX_EPOCH,
};

use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use serde::Serialize;
use serde_json::Value as JsonValue;
use serde_yaml::{Mapping, Value as YamlValue};

use crate::{ReaderError, ReaderPaths, ReaderResult};

// Serializes the moment the live index DB is mutated: every incremental
// upsert/remove transaction AND the full-reindex tmp→live rename take this
// lock, so no incremental writer is mid-transaction while the file is being
// swapped (the SQLite-corruption footgun of renaming an open DB). Critical
// sections are tiny — the slow embed phase of a reindex runs WITHOUT the lock,
// so autosaves never block on a multi-minute reindex.
static INDEX_WRITE_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, Serialize)]
pub struct IndexStats {
    pub scanned_files: usize,
    pub entries: usize,
    pub source_pdfs: usize,
    pub skipped_frontmatter_without_type: usize,
    pub by_type: BTreeMap<String, usize>,
    pub output: PathBuf,
}

#[derive(Debug)]
struct IndexedEntry {
    path: String,
    entry_type: String,
    book: Option<String>,
    title: Option<String>,
    author: Option<String>,
    year: Option<JsonValue>,
    rating: Option<JsonValue>,
    rating_score: f64,
    themes: Option<Vec<String>>,
    topic: Option<String>,
    source: Option<String>,
    doi: Option<String>,
    chapters_analyzed: Option<i64>,
    annotates: Option<String>,
    created: Option<String>,
    pdf_slug: Option<String>,
    has_pdf: bool,
    mtime: Option<i64>,
    preview: String,
    body_text: String,
    search_text: String,
}

/// Result of trying to turn one markdown file into an index row. Carries the
/// skip reason so the full reindex keeps its `skipped_frontmatter_without_type`
/// stat (the incremental path just ignores non-`Indexed` outcomes).
enum BuildOutcome {
    Indexed(Box<IndexedEntry>),
    SkippedNoType,
    Skipped,
}

/// Parse a single markdown file into an `IndexedEntry`. Shared by the full
/// reindex loop and the incremental upsert so both derive identical rows.
fn build_indexed_entry(
    paths: &ReaderPaths,
    file: &Path,
    source_slugs: &HashSet<String>,
) -> Result<BuildOutcome> {
    let text = fs::read_to_string(file)
        .with_context(|| format!("failed to read {}", file.display()))?;
    let meta = fs::metadata(file).ok();
    let (frontmatter, body) = parse_file(&text);
    let Some(frontmatter) = frontmatter else {
        return Ok(BuildOutcome::Skipped);
    };
    let Some(raw_type) = field_text(&frontmatter, "type") else {
        return Ok(BuildOutcome::SkippedNoType);
    };
    let Some(entry_type) = canonical_type(&raw_type) else {
        return Ok(BuildOutcome::Skipped);
    };

    let rel = slash_relative(&paths.workspace_root, file);
    let book = if entry_type == "chapter-summary" {
        book_slug(&rel)
    } else {
        None
    };
    let pdf_slug = match entry_type.as_str() {
        "paper-analysis" => file.file_stem().and_then(|s| s.to_str()).map(str::to_owned),
        "book-overview" => book_slug(&rel),
        _ => None,
    };
    // Exact slug→file match first; if missing, a conservative fuzzy match (same
    // lastname + strong title-token overlap + unique winner) so the many books
    // whose dir-slug was truncated/reworded still link to their source PDF.
    // pdf_slug stays the vault slug (stable id; translations key off it) — the
    // fuzzy resolution happens again at open time in resolve_source_pdf.
    let has_pdf = pdf_slug
        .as_ref()
        .map(|slug| {
            source_slugs.contains(slug) || crate::fuzzy_pick_source(slug, source_slugs).is_some()
        })
        .unwrap_or(false);

    let title = if entry_type == "note" {
        first_heading(body)
            .or_else(|| truthy_field_text(&frontmatter, "title").map(|s| strip_wiki(&s)))
            .or_else(|| truthy_field_text(&frontmatter, "name").map(|s| strip_wiki(&s)))
    } else {
        truthy_field_text(&frontmatter, "title")
            .or_else(|| truthy_field_text(&frontmatter, "name"))
            .map(|s| strip_wiki(&s))
    };

    let year = field_json(&frontmatter, "year");
    let rating_source = field(&frontmatter, "rating");
    let rating = rating_source.and_then(truthy_json);
    let themes = field(&frontmatter, "themes").and_then(theme_array);
    let author = field(&frontmatter, "author")
        .or_else(|| field(&frontmatter, "authors"))
        .and_then(flatten_author);

    let body_text = normalize_body_for_search(body);
    let preview = first_paragraph(body);
    let search_text = search_text(&[
        rel.as_str(),
        title.as_deref().unwrap_or_default(),
        author.as_deref().unwrap_or_default(),
        body_text.as_str(),
    ]);

    Ok(BuildOutcome::Indexed(Box::new(IndexedEntry {
        path: rel,
        entry_type,
        book,
        title,
        author,
        year,
        rating,
        rating_score: rating_source.map(rating_score).unwrap_or_default(),
        themes,
        topic: truthy_field_text(&frontmatter, "topic"),
        source: truthy_field_text(&frontmatter, "source"),
        doi: truthy_field_text(&frontmatter, "doi"),
        chapters_analyzed: field(&frontmatter, "chapters_analyzed").and_then(int_value),
        annotates: truthy_field_text(&frontmatter, "annotates"),
        created: field(&frontmatter, "created").and_then(text_value),
        pdf_slug,
        has_pdf,
        mtime: meta.and_then(|m| mtime_ms(&m).ok()),
        preview,
        body_text,
        search_text,
    })))
}

pub fn build_sqlite_index(paths: &ReaderPaths) -> ReaderResult<IndexStats> {
    crate::init_sqlite_vec();

    let mut files = Vec::new();
    walk_markdown(&paths.vault, &mut files)?;
    files.sort();

    let source_slugs = load_source_slugs(&paths.sources)?;
    let mut entries = Vec::new();
    let mut skipped_frontmatter_without_type = 0usize;

    for file in &files {
        match build_indexed_entry(paths, file, &source_slugs)? {
            BuildOutcome::Indexed(entry) => entries.push(*entry),
            BuildOutcome::SkippedNoType => skipped_frontmatter_without_type += 1,
            BuildOutcome::Skipped => {}
        }
    }

    entries.sort_by(|a, b| {
        a.entry_type
            .cmp(&b.entry_type)
            .then_with(|| b.rating_score.total_cmp(&a.rating_score))
            .then_with(|| {
                let a_title = a.title.as_deref().unwrap_or(&a.path);
                let b_title = b.title.as_deref().unwrap_or(&b.path);
                a_title.cmp(b_title)
            })
    });

    fs::create_dir_all(paths.index_db.parent().ok_or_else(|| {
        ReaderError::BadRequest("index database path has no parent".to_string())
    })?)?;
    write_sqlite_index(paths, &entries)?;

    let mut by_type = BTreeMap::new();
    for entry in &entries {
        *by_type.entry(entry.entry_type.clone()).or_insert(0) += 1;
    }

    Ok(IndexStats {
        scanned_files: files.len(),
        entries: entries.len(),
        source_pdfs: source_slugs.len(),
        skipped_frontmatter_without_type,
        by_type,
        output: paths.index_db.clone(),
    })
}

/// Opt-in vector pass: load BGE-M3 and (re)build a FRESH `vectors.sqlite`
/// holding only `entry_vectors`. Kept in its own DB so the fast, model-free
/// `build_sqlite_index` never wipes embeddings; hybrid search degrades to
/// lexical until this runs. Heavy (downloads/loads a ~2.3 GB model) — advanced.
pub fn build_embeddings(paths: &ReaderPaths) -> ReaderResult<usize> {
    build_embeddings_with_progress(paths, &|_, _| {})
}

/// Same as [`build_embeddings`] but reports progress as `(embedded, total)`.
/// `progress` fires once with `(0, total)` before embedding starts and again
/// after each batch, so a background job can surface live progress. Runs on the
/// calling (blocking) thread; the callback is invoked from that thread.
pub fn build_embeddings_with_progress(
    paths: &ReaderPaths,
    progress: &dyn Fn(usize, usize),
) -> ReaderResult<usize> {
    if !paths.index_db.is_file() {
        return Err(ReaderError::NotFound(
            "index database missing; run the index build first".to_string(),
        ));
    }
    crate::init_sqlite_vec();

    let mut files = Vec::new();
    walk_markdown(&paths.vault, &mut files)?;
    files.sort();
    let source_slugs = load_source_slugs(&paths.sources)?;
    let mut entries = Vec::new();
    for file in &files {
        if let BuildOutcome::Indexed(entry) = build_indexed_entry(paths, file, &source_slugs)? {
            entries.push(*entry);
        }
    }

    fs::create_dir_all(paths.vectors_db.parent().ok_or_else(|| {
        ReaderError::BadRequest("vectors database path has no parent".to_string())
    })?)?;
    let tmp = paths.vectors_db.with_extension("sqlite.tmp");
    if tmp.exists() {
        fs::remove_file(&tmp)?;
    }
    {
        let mut conn = Connection::open(&tmp)
            .with_context(|| format!("failed to open {}", tmp.display()))?;
        conn.execute_batch(
            r#"
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE VIRTUAL TABLE entry_vectors_staging USING vec0(
              path TEXT PRIMARY KEY,
              embedding float[1024] distance_metric=cosine
            );
            "#,
        )?;
        let tx = conn.transaction()?;
        embed_entries_into_staging(&tx, paths, &entries, progress)?;
        write_meta_keys(&tx)?;
        swap_staging_into_live(&tx)?; // creates entry_vectors from staging
        tx.commit()?;
    }
    // Atomic publish. A reader holding the old vectors.sqlite keeps its inode;
    // new readers see the new file. Separate file from index_db, so a metadata
    // reindex's own rename never touches this.
    fs::rename(&tmp, &paths.vectors_db)?;
    Ok(entries.len())
}

/// Path of the sentinel that proves BGE-M3 finished downloading at least once.
/// Written only after a successful `TextEmbedding::try_new`, so a partial or
/// corrupt download (which still leaves a non-empty cache dir) never trips the
/// boot auto-embed gate.
pub fn model_ready_marker(paths: &ReaderPaths) -> PathBuf {
    paths
        .reader_root
        .join("data")
        .join("models")
        .join(".model-ready")
}

/// True once the embedding model is known-good in the local cache. Boot
/// auto-embed only proceeds when this holds, so the server never kicks off a
/// surprise ~2.3 GB download on its own.
pub fn model_cache_ready(paths: &ReaderPaths) -> bool {
    model_ready_marker(paths).is_file()
}

fn load_source_slugs(sources: &Path) -> Result<HashSet<String>> {
    let mut slugs = HashSet::new();
    let Ok(entries) = fs::read_dir(sources) else {
        return Ok(slugs);
    };
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        if path
            .extension()
            .and_then(|ext| ext.to_str())
            .map(|ext| ext.eq_ignore_ascii_case("pdf"))
            .unwrap_or(false)
        {
            if let Some(stem) = path.file_stem().and_then(|stem| stem.to_str()) {
                slugs.insert(stem.to_string());
            }
        }
    }
    Ok(slugs)
}

fn walk_markdown(dir: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(dir).with_context(|| format!("failed to read {}", dir.display()))? {
        let entry = entry?;
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        let path = entry.path();
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            walk_markdown(&path, out)?;
        } else if (file_type.is_file() || file_type.is_symlink())
            && path.extension().and_then(|ext| ext.to_str()) == Some("md")
        {
            out.push(path);
        }
    }
    Ok(())
}

fn parse_file(text: &str) -> (Option<Mapping>, &str) {
    let Some(rest) = text
        .strip_prefix("---\n")
        .or_else(|| text.strip_prefix("---\r\n"))
    else {
        return (None, text);
    };

    let mut offset = 0usize;
    for line in rest.split_inclusive('\n') {
        let trimmed = line.trim_end_matches('\n').trim_end_matches('\r');
        if trimmed == "---" {
            let raw = &rest[..offset];
            let body = &rest[offset + line.len()..];
            let mapping = parse_frontmatter(raw);
            return (mapping, body);
        }
        offset += line.len();
    }

    (None, text)
}

fn parse_frontmatter(raw: &str) -> Option<Mapping> {
    match serde_yaml::from_str::<YamlValue>(raw).ok() {
        Some(YamlValue::Mapping(mapping)) => Some(mapping),
        _ if raw.contains("\\\"") => parse_lenient_mapping(raw),
        _ => None,
    }
}

fn parse_lenient_mapping(raw: &str) -> Option<Mapping> {
    let mut mapping = Mapping::new();
    let mut current_sequence_key: Option<YamlValue> = None;

    for line in raw.lines() {
        let line = line.trim_end();
        let trimmed = line.trim_start();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        if let Some(item) = trimmed.strip_prefix("- ") {
            if let Some(key) = current_sequence_key.clone() {
                let mut values = match mapping.remove(&key) {
                    Some(YamlValue::Sequence(values)) => values,
                    _ => Vec::new(),
                };
                values.push(parse_scalar(item));
                mapping.insert(key, YamlValue::Sequence(values));
            }
            continue;
        }

        let Some((key, value)) = line.split_once(':') else {
            current_sequence_key = None;
            continue;
        };
        if key.starts_with(char::is_whitespace) {
            current_sequence_key = None;
            continue;
        }

        let key_value = YamlValue::String(key.trim().to_string());
        let parsed_value = parse_scalar(value.trim());
        current_sequence_key = if matches!(parsed_value, YamlValue::Null) {
            Some(key_value.clone())
        } else {
            None
        };
        mapping.insert(key_value, parsed_value);
    }

    if mapping.is_empty() {
        None
    } else {
        Some(mapping)
    }
}

fn parse_scalar(raw: &str) -> YamlValue {
    if raw.is_empty() {
        return YamlValue::Null;
    }
    serde_yaml::from_str::<YamlValue>(raw).unwrap_or_else(|_| YamlValue::String(unquote(raw)))
}

fn unquote(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.len() >= 2 && trimmed.starts_with('"') && trimmed.ends_with('"') {
        return trimmed[1..trimmed.len() - 1]
            .replace("\\\"", "\"")
            .replace("\\\\", "\\");
    }
    if trimmed.len() >= 2 && trimmed.starts_with('\'') && trimmed.ends_with('\'') {
        return trimmed[1..trimmed.len() - 1].replace("''", "'");
    }
    trimmed.to_string()
}

fn first_paragraph(body: &str) -> String {
    let normalized = body.replace("\r\n", "\n");
    for paragraph in normalized.split("\n\n") {
        let trimmed = paragraph.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with("---") {
            continue;
        }
        if trimmed.starts_with("**") && trimmed.ends_with("**") && trimmed.len() < 80 {
            continue;
        }
        return trimmed
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(320)
            .collect();
    }
    String::new()
}

fn first_heading(body: &str) -> Option<String> {
    for line in body.lines() {
        let trimmed = line.trim();
        let hashes = trimmed.chars().take_while(|c| *c == '#').count();
        if hashes == 0 {
            continue;
        }
        let rest = &trimmed[hashes..];
        if rest.starts_with(char::is_whitespace) {
            let heading = rest.trim();
            if !heading.is_empty() {
                return Some(heading.to_string());
            }
        }
    }
    None
}

fn rating_score(value: &YamlValue) -> f64 {
    match value {
        YamlValue::Number(n) => n.as_f64().unwrap_or_default(),
        YamlValue::String(s) => {
            let stars = s.chars().filter(|c| *c == '★').count();
            if stars > 0 {
                stars as f64
            } else {
                s.parse::<f64>().unwrap_or_default()
            }
        }
        _ => 0.0,
    }
}

fn strip_wiki(input: &str) -> String {
    let mut output = String::new();
    let mut rest = input;
    while let Some(start) = rest.find("[[") {
        output.push_str(&rest[..start]);
        let after_open = &rest[start + 2..];
        let Some(end) = after_open.find("]]") else {
            output.push_str(&rest[start..]);
            return output;
        };
        let inner = &after_open[..end];
        let display = inner
            .split_once('|')
            .map(|(_, display)| display)
            .unwrap_or(inner)
            .trim();
        output.push_str(display);
        rest = &after_open[end + 2..];
    }
    output.push_str(rest);
    output
}

fn flatten_author(value: &YamlValue) -> Option<String> {
    match value {
        YamlValue::Null => None,
        YamlValue::Sequence(items) => {
            let authors = items
                .iter()
                .filter_map(text_value)
                .map(|s| strip_wiki(&s))
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>();
            Some(authors.join(", "))
        }
        _ => text_value(value).map(|s| strip_wiki(&s)),
    }
}

fn canonical_type(raw: &str) -> Option<String> {
    if raw.is_empty() || raw == "A" {
        return None;
    }
    let canonical = match raw {
        "paper"
        | "paper-summary"
        | "article-analysis"
        | "journal-article"
        | "journal-article-analysis" => "paper-analysis",
        "author" => "author-profile",
        "book" | "book-analysis" | "monograph" | "monograph-analysis" | "overview" => {
            "book-overview"
        }
        "chapter" | "book-chapter" | "book_chapter" | "chapter-analysis" => "chapter-summary",
        "journal-synthesis"
        | "snowball-synthesis"
        | "citation-snowball-synthesis"
        | "reading-list"
        | "research-note"
        | "concept-note" => "topic-synthesis",
        other => other,
    };
    Some(canonical.to_string())
}

fn field<'a>(mapping: &'a Mapping, name: &str) -> Option<&'a YamlValue> {
    mapping.iter().find_map(|(key, value)| {
        if key.as_str() == Some(name) {
            Some(value)
        } else {
            None
        }
    })
}

fn field_text(mapping: &Mapping, name: &str) -> Option<String> {
    field(mapping, name).and_then(text_value)
}

fn truthy_field_text(mapping: &Mapping, name: &str) -> Option<String> {
    field(mapping, name).and_then(|value| text_value(value).filter(|s| !s.is_empty()))
}

fn field_json(mapping: &Mapping, name: &str) -> Option<JsonValue> {
    field(mapping, name).and_then(yaml_to_json)
}

fn truthy_json(value: &YamlValue) -> Option<JsonValue> {
    match value {
        YamlValue::Null => None,
        YamlValue::Bool(false) => None,
        YamlValue::Number(n) if n.as_f64() == Some(0.0) => None,
        YamlValue::String(s) if s.is_empty() => None,
        _ => yaml_to_json(value),
    }
}

fn yaml_to_json(value: &YamlValue) -> Option<JsonValue> {
    match value {
        YamlValue::Null => None,
        _ => serde_json::to_value(value).ok(),
    }
}

fn text_value(value: &YamlValue) -> Option<String> {
    match value {
        YamlValue::Null => None,
        YamlValue::String(s) => Some(s.clone()),
        YamlValue::Bool(v) => Some(v.to_string()),
        YamlValue::Number(v) => Some(v.to_string()),
        _ => yaml_to_json(value).and_then(|json| serde_json::to_string(&json).ok()),
    }
}

fn int_value(value: &YamlValue) -> Option<i64> {
    match value {
        YamlValue::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|v| v.trunc() as i64)),
        YamlValue::String(s) => s.parse::<i64>().ok(),
        _ => None,
    }
}

fn theme_array(value: &YamlValue) -> Option<Vec<String>> {
    let YamlValue::Sequence(items) = value else {
        return None;
    };
    Some(items.iter().filter_map(text_value).collect())
}

fn json_cell(value: &Option<JsonValue>) -> Option<String> {
    value.as_ref().and_then(|v| serde_json::to_string(v).ok())
}

fn fts_json(value: &Option<JsonValue>) -> String {
    fn collect(value: &JsonValue, out: &mut Vec<String>) {
        match value {
            JsonValue::Null => {}
            JsonValue::String(s) => out.push(s.clone()),
            JsonValue::Number(n) => out.push(n.to_string()),
            JsonValue::Bool(b) => out.push(b.to_string()),
            JsonValue::Array(items) => {
                for item in items {
                    collect(item, out);
                }
            }
            JsonValue::Object(_) => out.push(value.to_string()),
        }
    }

    let mut out = Vec::new();
    if let Some(value) = value {
        collect(value, &mut out);
    }
    out.join(" ")
}

fn book_slug(rel: &str) -> Option<String> {
    rel.strip_prefix("vault/books/")
        .and_then(|rest| rest.split('/').next())
        .filter(|slug| !slug.is_empty())
        .map(str::to_owned)
}

fn mtime_ms(meta: &fs::Metadata) -> Result<i64> {
    let modified = meta.modified()?;
    let duration = modified.duration_since(UNIX_EPOCH)?;
    Ok(duration.as_millis() as i64)
}

fn slash_relative(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .components()
        .map(|component| component.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}

fn write_sqlite_index(paths: &ReaderPaths, entries: &[IndexedEntry]) -> ReaderResult<()> {
    let tmp = paths.index_db.with_extension("sqlite.tmp");
    if tmp.exists() {
        fs::remove_file(&tmp)?;
    }

    let mut conn =
        Connection::open(&tmp).with_context(|| format!("failed to open {}", tmp.display()))?;
    conn.execute_batch(
        r#"
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        DROP TABLE IF EXISTS entries;
        DROP TABLE IF EXISTS entry_themes;
        DROP TABLE IF EXISTS entry_search;
        DROP TABLE IF EXISTS entry_text;
        DROP TABLE IF EXISTS entry_trigram;
        DROP TABLE IF EXISTS meta;
        DROP TABLE IF EXISTS entry_vectors;
        DROP TABLE IF EXISTS entry_vectors_staging;

        CREATE TABLE entries (
          path TEXT PRIMARY KEY,
          type TEXT NOT NULL,
          book TEXT,
          title TEXT,
          author TEXT,
          year_json TEXT,
          rating_json TEXT,
          rating_score REAL NOT NULL DEFAULT 0,
          themes_json TEXT,
          topic TEXT,
          source TEXT,
          doi TEXT,
          chapters_analyzed INTEGER,
          annotates TEXT,
          created TEXT,
          pdf_slug TEXT,
          has_pdf INTEGER NOT NULL DEFAULT 0,
          mtime INTEGER,
          preview TEXT NOT NULL DEFAULT ''
        );

        CREATE TABLE entry_text (
          path TEXT PRIMARY KEY,
          search_text TEXT NOT NULL,
          FOREIGN KEY (path) REFERENCES entries(path) ON DELETE CASCADE
        );

        CREATE TABLE entry_themes (
          path TEXT NOT NULL,
          theme TEXT NOT NULL,
          type TEXT NOT NULL,
          PRIMARY KEY (path, theme),
          FOREIGN KEY (path) REFERENCES entries(path) ON DELETE CASCADE
        );

        CREATE VIRTUAL TABLE entry_search USING fts5(
          path UNINDEXED,
          type UNINDEXED,
          title,
          author,
          book,
          themes,
          topic,
          source,
          year,
          preview,
          doi,
          body
        );

        CREATE VIRTUAL TABLE entry_trigram USING fts5(
          path UNINDEXED,
          type UNINDEXED,
          text,
          tokenize = 'trigram'
        );

        CREATE TABLE meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );

        CREATE INDEX entries_type_rating_title_idx
          ON entries(type, rating_score DESC, title COLLATE NOCASE);
        CREATE INDEX entries_annotates_idx ON entries(annotates);
        CREATE INDEX entries_mtime_idx ON entries(mtime DESC);
        CREATE INDEX entry_themes_theme_idx ON entry_themes(theme, type);
        "#,
    )?;

    let tx = conn.transaction()?;
    {
        for entry in entries {
            insert_indexed_entry(&tx, entry)?;
        }
        // Embeddings are a separate, opt-in pass (`build_embeddings`) so the
        // default index build stays fast and model-free — no entry_vectors here.
    }
    tx.commit()?;
    drop(conn);
    {
        // Hold the write lock only for the swap so no incremental upsert is
        // mid-transaction on the old DB file while it is replaced.
        let _swap = INDEX_WRITE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        fs::rename(&tmp, &paths.index_db)?;
    }
    Ok(())
}

/// Insert one entry's rows across the metadata + FTS tables. Shared by the full
/// reindex and the incremental upsert so the column logic lives in one place.
/// Does NOT touch `entry_vectors` — embeddings are produced only by full reindex.
fn insert_indexed_entry(conn: &Connection, entry: &IndexedEntry) -> rusqlite::Result<()> {
    let themes_json = entry
        .themes
        .as_ref()
        .and_then(|themes| serde_json::to_string(themes).ok());
    conn.execute(
        r#"
        INSERT INTO entries (
          path, type, book, title, author, year_json, rating_json, rating_score,
          themes_json, topic, source, doi, chapters_analyzed, annotates, created,
          pdf_slug, has_pdf, mtime, preview
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        "#,
        params![
            entry.path,
            entry.entry_type,
            entry.book,
            entry.title,
            entry.author,
            json_cell(&entry.year),
            json_cell(&entry.rating),
            entry.rating_score,
            themes_json,
            entry.topic,
            entry.source,
            entry.doi,
            entry.chapters_analyzed,
            entry.annotates,
            entry.created,
            entry.pdf_slug,
            if entry.has_pdf { 1 } else { 0 },
            entry.mtime,
            entry.preview,
        ],
    )?;

    if let Some(themes) = &entry.themes {
        for theme in themes {
            if !theme.is_empty() {
                conn.execute(
                    "INSERT INTO entry_themes (path, theme, type) VALUES (?, ?, ?)",
                    params![entry.path, theme, entry.entry_type],
                )?;
            }
        }
    }

    conn.execute(
        "INSERT INTO entry_text (path, search_text) VALUES (?, ?)",
        params![entry.path, entry.search_text],
    )?;

    conn.execute(
        r#"
        INSERT INTO entry_search (
          path, type, title, author, book, themes, topic, source, year, preview, doi, body
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        "#,
        params![
            entry.path,
            entry.entry_type,
            entry.title,
            entry.author,
            entry.book,
            entry.themes.as_ref().map(|themes| themes.join(" ")),
            entry.topic,
            entry.source,
            fts_json(&entry.year),
            entry.preview,
            entry.doi,
            entry.body_text,
        ],
    )?;

    conn.execute(
        "INSERT INTO entry_trigram (path, type, text) VALUES (?, ?, ?)",
        params![entry.path, entry.entry_type, entry.search_text],
    )?;

    Ok(())
}

impl IndexedEntry {
    /// Project the internal index row onto the public `Entry` shape (drops the
    /// search-only `body_text` / `search_text`).
    fn into_public(self) -> crate::Entry {
        crate::Entry {
            path: self.path,
            entry_type: self.entry_type,
            book: self.book,
            title: self.title,
            author: self.author,
            year: self.year,
            rating: self.rating,
            rating_score: self.rating_score,
            themes: self.themes,
            topic: self.topic,
            source: self.source,
            doi: self.doi,
            chapters_analyzed: self.chapters_analyzed,
            annotates: self.annotates,
            created: self.created,
            has_pdf: self.has_pdf,
            pdf_slug: self.pdf_slug,
            mtime: self.mtime,
            preview: self.preview,
        }
    }
}

/// Cheap directory listing of the vault: path + mtime for every `.md` file, no
/// frontmatter parsing. The file-browser view diffs this against its cached
/// entries to find what changed since the last index build — files are the
/// source of truth; the DB is only a metadata cache.
pub fn list_vault_files(paths: &ReaderPaths) -> ReaderResult<Vec<crate::VaultFile>> {
    let mut files = Vec::new();
    walk_markdown(&paths.vault, &mut files)?;
    files.sort();
    let mut out = Vec::with_capacity(files.len());
    for file in &files {
        let mtime = fs::metadata(file).ok().and_then(|m| mtime_ms(&m).ok());
        out.push(crate::VaultFile {
            path: slash_relative(&paths.workspace_root, file),
            mtime,
        });
    }
    Ok(out)
}

/// Parse ONE vault file into a public `Entry` using the same frontmatter rules
/// as the full index build (single source of truth) — no DB, no model. Returns
/// `None` when the file is missing or has no usable `type`, so the file-browser
/// can skip non-entries without thrashing. Path is validated under vault.
pub fn parse_entry(paths: &ReaderPaths, rel_path: &str) -> ReaderResult<Option<crate::Entry>> {
    let target = crate::safe_join(&paths.workspace_root, rel_path.trim_start_matches('/'))?;
    crate::ensure_markdown(&target)?;
    crate::ensure_under(&target, &paths.vault, "only vault files can be parsed")?;
    if !target.is_file() {
        return Ok(None);
    }
    let source_slugs = load_source_slugs(&paths.sources)?;
    match build_indexed_entry(paths, &target, &source_slugs)? {
        BuildOutcome::Indexed(entry) => Ok(Some(entry.into_public())),
        _ => Ok(None),
    }
}

const EMBED_INPUT_CHAR_CAP: usize = 8192 * 4; // ~8192 tokens, char proxy
const EMBED_BATCH: usize = 8;
const EMBED_MODEL_ID: &str = "BAAI/bge-m3";
const EMBED_DIM: usize = 1024;

fn embed_entries_into_staging(
    tx: &rusqlite::Transaction<'_>,
    paths: &ReaderPaths,
    entries: &[IndexedEntry],
    progress: &dyn Fn(usize, usize),
) -> ReaderResult<()> {
    let total = entries.len();
    progress(0, total);
    if entries.is_empty() {
        // No entries → nothing to embed; skip the 2.3 GB model init entirely.
        // A reindex of an empty/filtered vault should still produce a valid
        // (but empty) entry_vectors table after the swap step.
        let _ = tx;
        return Ok(());
    }

    use fastembed::{EmbeddingModel, InitOptions, TextEmbedding};

    let model_cache = paths.reader_root.join("data").join("models");
    fs::create_dir_all(&model_cache)?;
    let mut model = TextEmbedding::try_new(
        InitOptions::new(EmbeddingModel::BGEM3)
            .with_show_download_progress(true)
            .with_cache_dir(model_cache),
    )
    .map_err(|e| ReaderError::Other(anyhow::anyhow!("init BGE-M3: {e}")))?;

    // Model is fully loaded → record the ready sentinel so boot auto-embed may
    // run unattended next time without risking a partial-download false positive.
    if let Err(e) = fs::write(model_ready_marker(paths), b"ok") {
        eprintln!("[reader-core] could not write model-ready marker: {e}");
    }

    let mut insert_vec = tx.prepare(
        "INSERT INTO entry_vectors_staging(path, embedding) VALUES (?, ?)",
    )?;

    for (batch_idx, chunk) in entries.chunks(EMBED_BATCH).enumerate() {
        let texts: Vec<String> = chunk
            .iter()
            .map(|e| {
                build_embed_input(
                    e.title.as_deref(),
                    e.author.as_deref(),
                    &e.preview,
                    &e.body_text,
                )
            })
            .collect();
        let vecs = model
            .embed(texts, None)
            .map_err(|e| ReaderError::Other(anyhow::anyhow!("embed batch: {e}")))?;
        for (entry, v) in chunk.iter().zip(vecs.into_iter()) {
            // BGE-M3 already L2-normalizes its output; no extra renorm needed.
            let bytes: Vec<u8> = v.iter().flat_map(|f| f.to_le_bytes()).collect();
            insert_vec.execute(params![entry.path, bytes])?;
        }
        let done = ((batch_idx + 1) * EMBED_BATCH).min(total);
        progress(done, total);
        if done.is_multiple_of(80) || done >= total {
            eprintln!("  embedded {done}/{total}");
        }
    }
    Ok(())
}

/// Move the freshly-populated `entry_vectors_staging` virtual table into the
/// canonical `entry_vectors` slot. sqlite-vec's vec0 virtual table does not
/// support `ALTER TABLE … RENAME TO`, so we explicitly recreate `entry_vectors`
/// and copy rows. The whole thing runs inside the outer transaction, so the
/// swap is atomic.
fn swap_staging_into_live(tx: &rusqlite::Transaction<'_>) -> ReaderResult<()> {
    tx.execute("DROP TABLE IF EXISTS entry_vectors", [])?;
    tx.execute(
        "CREATE VIRTUAL TABLE entry_vectors USING vec0(path TEXT PRIMARY KEY, embedding float[1024] distance_metric=cosine)",
        [],
    )?;
    tx.execute(
        "INSERT INTO entry_vectors(path, embedding) SELECT path, embedding FROM entry_vectors_staging",
        [],
    )?;
    tx.execute("DROP TABLE entry_vectors_staging", [])?;
    Ok(())
}

fn write_meta_keys(tx: &rusqlite::Transaction<'_>) -> ReaderResult<()> {
    // INSERT OR REPLACE so re-running the embedding pass doesn't hit a PK clash.
    tx.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES ('embed_model', ?)",
        params![EMBED_MODEL_ID],
    )?;
    tx.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES ('embed_dim', ?)",
        params![EMBED_DIM as i64],
    )?;
    tx.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES ('embed_completed_at', ?)",
        params![chrono::Utc::now().to_rfc3339()],
    )?;
    Ok(())
}

fn build_embed_input(
    title: Option<&str>,
    author: Option<&str>,
    preview: &str,
    body: &str,
) -> String {
    let mut buf = String::from("passage: ");
    if let Some(t) = title {
        buf.push_str(t);
        buf.push('\n');
    }
    if let Some(a) = author {
        buf.push_str(a);
        buf.push('\n');
    }
    buf.push_str(preview);
    buf.push('\n');
    let body_truncated = body.chars().take(EMBED_INPUT_CHAR_CAP).collect::<String>();
    buf.push_str(&body_truncated);
    buf
}

fn normalize_body_for_search(body: &str) -> String {
    body.replace("\r\n", "\n")
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

fn search_text(parts: &[&str]) -> String {
    parts
        .iter()
        .map(|part| part.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_legacy_escaped_quote_frontmatter() {
        let raw = r#"type: "chapter-summary"
rating:
themes: []
author:
  - "[[chris-salter|Chris Salter]]"
title: "Chapter 3 - \"You Are the Controller\""
year: 2022
"#;

        let mapping = parse_frontmatter(raw).expect("frontmatter should parse");

        assert_eq!(
            field_text(&mapping, "title").as_deref(),
            Some("Chapter 3 - \"You Are the Controller\"")
        );
        assert_eq!(
            flatten_author(field(&mapping, "author").unwrap()).as_deref(),
            Some("Chris Salter")
        );
    }

    #[test]
    fn rejects_frontmatter_that_legacy_yaml_skipped() {
        let raw = r#"book: Understanding Dogs: Living and Working with Canine Companions
author: Clinton Sanders
type: chapter-summary
"#;

        assert!(parse_frontmatter(raw).is_none());
    }

    #[test]
    fn strip_wiki_prefers_display_text() {
        assert_eq!(
            strip_wiki("[[shaun-gallagher|Shaun Gallagher]]"),
            "Shaun Gallagher"
        );
    }
}
