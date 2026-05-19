use std::{
    collections::{BTreeMap, HashSet},
    fs,
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use serde::Serialize;
use serde_json::Value as JsonValue;
use serde_yaml::{Mapping, Value as YamlValue};

use crate::{ReaderError, ReaderPaths, ReaderResult};

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

pub fn build_sqlite_index(paths: &ReaderPaths) -> ReaderResult<IndexStats> {
    let mut files = Vec::new();
    walk_markdown(&paths.vault, &mut files)?;
    files.sort();

    let source_slugs = load_source_slugs(&paths.sources)?;
    let mut entries = Vec::new();
    let mut skipped_frontmatter_without_type = 0usize;

    for file in &files {
        let text = fs::read_to_string(file)
            .with_context(|| format!("failed to read {}", file.display()))?;
        let meta = fs::metadata(file).ok();
        let (frontmatter, body) = parse_file(&text);
        let Some(frontmatter) = frontmatter else {
            continue;
        };
        let Some(raw_type) = field_text(&frontmatter, "type") else {
            skipped_frontmatter_without_type += 1;
            continue;
        };
        let Some(entry_type) = canonical_type(&raw_type) else {
            continue;
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
        let has_pdf = pdf_slug
            .as_ref()
            .map(|slug| source_slugs.contains(slug))
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

        entries.push(IndexedEntry {
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
        });
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

        CREATE VIRTUAL TABLE entry_vectors_staging USING vec0(
          path TEXT PRIMARY KEY,
          embedding float[1024] distance_metric=cosine
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
        let mut insert_entry = tx.prepare(
            r#"
            INSERT INTO entries (
              path, type, book, title, author, year_json, rating_json, rating_score,
              themes_json, topic, source, doi, chapters_analyzed, annotates, created,
              pdf_slug, has_pdf, mtime, preview
            ) VALUES (
              ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            )
            "#,
        )?;
        let mut insert_theme =
            tx.prepare("INSERT INTO entry_themes (path, theme, type) VALUES (?, ?, ?)")?;
        let mut insert_text =
            tx.prepare("INSERT INTO entry_text (path, search_text) VALUES (?, ?)")?;
        let mut insert_search = tx.prepare(
            r#"
            INSERT INTO entry_search (
              path, type, title, author, book, themes, topic, source, year, preview, doi, body
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            "#,
        )?;
        let mut insert_trigram = tx.prepare(
            r#"
            INSERT INTO entry_trigram (
              path, type, text
            ) VALUES (?, ?, ?)
            "#,
        )?;

        for entry in entries {
            let themes_json = entry
                .themes
                .as_ref()
                .and_then(|themes| serde_json::to_string(themes).ok());
            insert_entry.execute(params![
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
            ])?;

            if let Some(themes) = &entry.themes {
                for theme in themes {
                    if !theme.is_empty() {
                        insert_theme.execute(params![entry.path, theme, entry.entry_type])?;
                    }
                }
            }

            insert_text.execute(params![entry.path, entry.search_text])?;

            insert_search.execute(params![
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
            ])?;

            insert_trigram.execute(params![
                entry.path,
                entry.entry_type,
                entry.search_text,
            ])?;
        }
    }
    tx.commit()?;
    drop(conn);
    fs::rename(&tmp, &paths.index_db)?;
    Ok(())
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
