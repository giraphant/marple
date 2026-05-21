#!/usr/bin/env node

import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DB_FILE = path.resolve(__dirname, '../data/index.sqlite');

assert.ok(existsSync(DB_FILE), `missing SQLite index: ${DB_FILE}`);

const db = new DatabaseSync(DB_FILE, { readOnly: true });

try {
  const tables = new Set(
    db.prepare(`
      SELECT name
      FROM sqlite_master
      WHERE type IN ('table', 'virtual table')
    `).all().map(row => row.name),
  );

  assert.ok(tables.has('entries'), 'entries table missing');
  assert.ok(tables.has('entry_themes'), 'entry_themes table missing');
  assert.ok(tables.has('entry_search'), 'entry_search FTS table missing');

  const entryColumns = new Set(db.prepare('PRAGMA table_info(entries)').all().map(row => row.name));
  for (const column of ['title_en', 'title_cn', 'publisher', 'isbn', 'translation_title_cn', 'translation_douban_url']) {
    assert.ok(entryColumns.has(column), `entries.${column} column missing`);
  }

  const total = db.prepare('SELECT count(*) AS n FROM entries').get().n;
  const searchTotal = db.prepare('SELECT count(*) AS n FROM entry_search').get().n;
  assert.ok(total > 0, 'entries table is empty');
  assert.equal(searchTotal, total, 'FTS row count must match entries');

  const requiredTypes = [
    'paper-analysis',
    'book-overview',
    'chapter-summary',
    'author-profile',
    'topic-synthesis',
    'note',
  ];
  for (const type of requiredTypes) {
    const n = db.prepare('SELECT count(*) AS n FROM entries WHERE type = ?').get(type).n;
    assert.ok(n > 0, `expected indexed rows for ${type}`);
  }

  const bookMetadataRows = db.prepare(`
    SELECT count(*) AS n
    FROM entries
    WHERE type = 'book-overview'
      AND (publisher IS NOT NULL OR isbn IS NOT NULL OR title_cn IS NOT NULL)
  `).get().n;
  assert.ok(bookMetadataRows > 0, 'expected book overview rows with bibliographic metadata');

  const chapterTitleRows = db.prepare(`
    SELECT count(*) AS n
    FROM entries
    WHERE type = 'chapter-summary'
      AND (title_en IS NOT NULL OR title_cn IS NOT NULL)
  `).get().n;
  assert.ok(chapterTitleRows > 0, 'expected chapter title alias metadata');

  const chineseTranslationRows = db.prepare(`
    SELECT count(*) AS n
    FROM entries
    WHERE type = 'book-overview'
      AND translation_douban_url IS NOT NULL
  `).get().n;
  assert.ok(chineseTranslationRows > 0, 'expected Chinese translation Douban metadata');

  const badThemeRows = db.prepare(`
    SELECT count(*) AS n
    FROM entry_themes
    WHERE theme IS NULL OR theme = ''
  `).get().n;
  assert.equal(badThemeRows, 0, 'entry_themes should not contain empty themes');

  const expandedThemeCount = db.prepare(`
    SELECT coalesce(sum(json_array_length(themes_json)), 0) AS n
    FROM entries
    WHERE themes_json IS NOT NULL
  `).get().n;
  const themeRows = db.prepare('SELECT count(*) AS n FROM entry_themes').get().n;
  assert.equal(themeRows, expandedThemeCount, 'entry_themes must mirror themes_json');

  const sample = db.prepare(`
    SELECT title, path
    FROM entries
    WHERE title GLOB '*[A-Za-z]*'
    ORDER BY rating_score DESC, title
    LIMIT 1
  `).get();
  assert.ok(sample, 'expected an ASCII-title sample row for FTS smoke test');

  const token = (sample.title.match(/[A-Za-z0-9]{4,}/) || sample.path.match(/[A-Za-z0-9]{4,}/) || [])[0];
  assert.ok(token, 'sample row should yield a searchable token');

  const matches = db.prepare(`
    SELECT count(*) AS n
    FROM entry_search
    WHERE entry_search MATCH ?
  `).get(token).n;
  assert.ok(matches > 0, `FTS smoke query should match token: ${token}`);

  const parseable = db.prepare(`
    SELECT year_json, rating_json, themes_json
    FROM entries
    WHERE year_json IS NOT NULL
       OR rating_json IS NOT NULL
       OR themes_json IS NOT NULL
    LIMIT 100
  `).all();
  for (const row of parseable) {
    for (const key of ['year_json', 'rating_json', 'themes_json']) {
      if (row[key] != null) assert.doesNotThrow(() => JSON.parse(row[key]), `${key} must be JSON`);
    }
  }

  console.log(`ok sql index: ${total} entries, ${themeRows} theme rows, FTS token "${token}"`);
} finally {
  db.close();
}
