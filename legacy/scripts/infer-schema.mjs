#!/usr/bin/env node
// Read-only schema inference. Walks vault/, parses frontmatter, groups by
// canonical type, and reports per-field stats: fill rate, type distribution,
// enum candidates, value ranges, sample values. Output is human-readable
// markdown intended to drive Zod schema design.

import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { workspaceRoot, marpleDataDir } from './workspace-root.mjs';

const ROOT = workspaceRoot();
const VAULT = path.join(ROOT, 'vault');
const OUT = marpleDataDir();
const REPORT = path.join(OUT, 'schema-inference.md');

// ---- parser (mirror of build-index.mjs) ----

async function walk(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const out = [];
  for (const e of entries) {
    if (e.name.startsWith('.')) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...await walk(p));
    else if (e.name.endsWith('.md')) out.push(p);
  }
  return out;
}

function stripQuotes(s) {
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    return s.slice(1, -1);
  }
  return s;
}
function parseValue(v) {
  v = v.trim();
  if (v === '' || v === '~' || v === 'null') return null;
  if (v.startsWith('[') && v.endsWith(']')) {
    const inner = v.slice(1, -1).trim();
    if (!inner) return [];
    return inner.split(',').map(s => stripQuotes(s.trim())).filter(Boolean);
  }
  if (/^-?\d+$/.test(v)) return Number(v);
  if (/^-?\d+\.\d+$/.test(v)) return Number(v);
  return stripQuotes(v);
}
function parseFrontmatter(text) {
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return { fm: null };
  const fm = {};
  const lines = m[1].split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const kv = line.match(/^([a-zA-Z_][a-zA-Z0-9_-]*):\s*(.*)$/);
    if (!kv) continue;
    const key = kv[1];
    const raw = kv[2];
    if (raw.trim() === '') {
      const items = [];
      while (i + 1 < lines.length && /^\s+-\s+/.test(lines[i + 1])) {
        items.push(stripQuotes(lines[++i].replace(/^\s+-\s+/, '').trim()));
      }
      fm[key] = items.length ? items : null;
    } else {
      fm[key] = parseValue(raw);
    }
  }
  return { fm };
}

const TYPE_ALIAS = {
  paper: 'paper-analysis',
  'paper-summary': 'paper-analysis',
  'article-analysis': 'paper-analysis',
  'journal-article': 'paper-analysis',
  'journal-article-analysis': 'paper-analysis',
  book: 'book-overview',
  'book-analysis': 'book-overview',
  monograph: 'book-overview',
  'monograph-analysis': 'book-overview',
  overview: 'book-overview',
  chapter: 'chapter-summary',
  'book-chapter': 'chapter-summary',
  book_chapter: 'chapter-summary',
  'chapter-analysis': 'chapter-summary',
  'journal-synthesis': 'topic-synthesis',
  'snowball-synthesis': 'topic-synthesis',
  'citation-snowball-synthesis': 'topic-synthesis',
  'reading-list': 'topic-synthesis',
  'research-note': 'topic-synthesis',
  'concept-note': 'topic-synthesis',
};
function canonicalType(t) {
  if (!t || t === 'A') return null;
  return TYPE_ALIAS[t] || t;
}

// ---- stats collection ----

function bumpField(slot, value, filePath) {
  slot.count++;
  if (value == null) {
    slot.types.null = (slot.types.null || 0) + 1;
    slot.nullCount++;
    return;
  }
  if (Array.isArray(value)) {
    slot.types.array = (slot.types.array || 0) + 1;
    slot.arrayLengths.push(value.length);
    if (value.length === 0) slot.emptyArrayCount++;
    for (const v of value) {
      const key = typeof v === 'string' ? v : JSON.stringify(v);
      if (slot.values.size < 500) slot.values.add(key);
    }
    return;
  }
  const t = typeof value;
  slot.types[t] = (slot.types[t] || 0) + 1;
  const key = t === 'string' ? value : JSON.stringify(value);
  if (slot.values.size < 500) slot.values.add(key);
  if (slot.examples.length < 6 && !slot.examples.includes(key)) slot.examples.push({ value: key, path: filePath });
}

function mkSlot() {
  return {
    count: 0,
    nullCount: 0,
    emptyArrayCount: 0,
    types: {},
    values: new Set(),
    arrayLengths: [],
    examples: [],
  };
}

// ---- formatter ----

function pct(n, d) { return d === 0 ? '0%' : `${(n / d * 100).toFixed(0)}%`; }
function truncate(s, n = 60) { return s.length > n ? s.slice(0, n) + '…' : s; }

function classify(slot, totalForType) {
  // Non-null fill rate determines required vs optional.
  const filled = slot.count - slot.nullCount - slot.emptyArrayCount;
  const rate = filled / totalForType;
  if (rate >= 0.97) return 'req';
  if (rate >= 0.50) return 'opt';
  return 'rare';
}

function fmtField(name, slot, totalForType) {
  const tag = classify(slot, totalForType);
  const fill = pct(slot.count, totalForType);
  const nonNull = pct(slot.count - slot.nullCount - slot.emptyArrayCount, totalForType);
  const typeStr = Object.entries(slot.types)
    .filter(([t]) => t !== 'null')
    .map(([t, n]) => `${t}×${n}`)
    .join(' ');

  let detail = '';
  if (slot.types.array) {
    const lens = slot.arrayLengths.filter(x => x > 0);
    if (lens.length) {
      const avg = (lens.reduce((a, b) => a + b, 0) / lens.length).toFixed(1);
      const mx = Math.max(...lens);
      detail = `array · avg ${avg} items, max ${mx} · ${slot.values.size}${slot.values.size === 500 ? '+' : ''} unique elements`;
    } else {
      detail = `array · all empty`;
    }
  } else if (slot.types.number) {
    const nums = [...slot.values].map(Number).filter(x => !isNaN(x));
    if (nums.length) {
      const mn = Math.min(...nums), mx = Math.max(...nums);
      detail = `number · range ${mn}..${mx}`;
    }
  } else if (slot.values.size <= 12 && (slot.types.string || slot.types.boolean)) {
    detail = `ENUM (${slot.values.size}) · { ${[...slot.values].map(v => truncate(v, 30)).join(' | ')} }`;
  } else {
    detail = `${slot.values.size}${slot.values.size === 500 ? '+' : ''} unique`;
    const samples = slot.examples.slice(0, 3).map(e => truncate(e.value, 50));
    if (samples.length) detail += ` · e.g. ${samples.map(s => `"${s}"`).join(', ')}`;
  }

  return `- \`${name}\` **${tag}** · fill ${fill} / non-null ${nonNull} · ${typeStr} · ${detail}`;
}

function fmtReport(byType) {
  const order = Object.entries(byType).sort((a, b) => b[1].total - a[1].total);
  const lines = [];
  lines.push('# qua-vault schema inference');
  lines.push('');
  lines.push(`Generated: ${new Date().toISOString()}`);
  lines.push(`Types: ${order.length}, total typed entries: ${order.reduce((s, [, v]) => s + v.total, 0)}`);
  lines.push('');
  lines.push('Field tag legend: **req** = filled in ≥97% of entries · **opt** = 50–97% · **rare** = <50%');
  lines.push('');

  for (const [type, info] of order) {
    lines.push(`## \`${type}\` — ${info.total} entries`);
    lines.push('');
    const fields = Object.entries(info.fields).sort((a, b) => b[1].count - a[1].count);
    for (const [name, slot] of fields) {
      lines.push(fmtField(name, slot, info.total));
    }
    lines.push('');
  }

  // Cross-type field summary: which fields appear in which types?
  const fieldOwners = new Map();
  for (const [type, info] of order) {
    for (const name of Object.keys(info.fields)) {
      if (!fieldOwners.has(name)) fieldOwners.set(name, new Set());
      fieldOwners.get(name).add(type);
    }
  }
  lines.push(`## cross-type field map`);
  lines.push('');
  const fieldList = [...fieldOwners.entries()].sort((a, b) => b[1].size - a[1].size || a[0].localeCompare(b[0]));
  for (const [field, types] of fieldList) {
    lines.push(`- \`${field}\` → ${[...types].map(t => `\`${t}\``).join(', ')}`);
  }

  return lines.join('\n');
}

// ---- main ----

(async () => {
  console.log('scanning', VAULT);
  const files = await walk(VAULT);
  console.log(`found ${files.length} md files`);

  const byType = {}; // canonical type → { total, fields: { name → slot } }

  for (const f of files) {
    const text = await readFile(f, 'utf8');
    const { fm } = parseFrontmatter(text);
    if (!fm || !fm.type) continue;
    const type = canonicalType(fm.type);
    if (!type) continue;
    if (!byType[type]) byType[type] = { total: 0, fields: {} };
    byType[type].total++;
    const rel = path.relative(ROOT, f).split(path.sep).join('/');
    for (const [k, v] of Object.entries(fm)) {
      if (k === 'type') continue;
      if (!byType[type].fields[k]) byType[type].fields[k] = mkSlot();
      bumpField(byType[type].fields[k], v, rel);
    }
  }

  await mkdir(OUT, { recursive: true });
  const report = fmtReport(byType);
  await writeFile(REPORT, report);

  // Console summary.
  console.log('\nby type:');
  for (const [t, info] of Object.entries(byType).sort((a, b) => b[1].total - a[1].total)) {
    console.log(`  ${t.padEnd(20)} ${String(info.total).padStart(6)} entries, ${Object.keys(info.fields).length} fields`);
  }
  console.log(`\nfull report → ${path.relative(ROOT, REPORT)}`);
})();
