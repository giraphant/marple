#!/usr/bin/env node
// Read-only body audit. Walks vault/, for each typed entity:
//   1. extracts every `## H2 heading` and its content (up to next H2)
//   2. detects the dominant block kind of that content
//      (paragraph / bullet-list / numbered-list / table / blockquote / definition-list / mixed / empty)
// Aggregates per canonical type:
//   - top H2 headings by frequency
//   - for each top H2: block-kind distribution
//   - overall block-kind distribution
// Writes reader/data/body-audit.md.

import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '../..');
const VAULT = path.join(ROOT, 'vault');
const OUT = path.resolve(__dirname, '../data');
const REPORT = path.join(OUT, 'body-audit.md');

// ---- file walk ----

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

// ---- minimal frontmatter sniff (just want type) ----

const TYPE_ALIAS = {
  'author-profile': 'author',
  'book-overview': 'book',
  'book': 'book', 'book-analysis': 'book', 'monograph': 'book', 'monograph-analysis': 'book', 'overview': 'book',
  'chapter-summary': 'chapter',
  'chapter': 'chapter', 'book-chapter': 'chapter', 'book_chapter': 'chapter', 'chapter-analysis': 'chapter',
  'paper-analysis': 'paper',
  'paper': 'paper', 'paper-summary': 'paper', 'article-analysis': 'paper', 'journal-article': 'paper', 'journal-article-analysis': 'paper',
};

function canonicalType(t) {
  if (!t || t === 'A') return null;
  return TYPE_ALIAS[t] || null; // only count the 4 canonical types
}

function extractTypeAndBody(text) {
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return { type: null, body: text };
  const typeMatch = m[1].match(/^type:\s*(.+?)\s*$/m);
  const rawType = typeMatch ? typeMatch[1].replace(/^["']|["']$/g, '').trim() : null;
  return { type: canonicalType(rawType), body: m[2] };
}

// ---- H2 extraction ----

function extractH2Sections(body) {
  const lines = body.split('\n');
  const sections = [];
  let current = null;
  let inCodeBlock = false;
  for (const line of lines) {
    if (line.startsWith('```')) {
      inCodeBlock = !inCodeBlock;
      if (current) current.lines.push(line);
      continue;
    }
    if (!inCodeBlock) {
      const m = line.match(/^## (?!#)(.+?)\s*$/);
      if (m) {
        if (current) sections.push(current);
        current = { heading: m[1].trim(), lines: [] };
        continue;
      }
    }
    if (current) current.lines.push(line);
  }
  if (current) sections.push(current);
  return sections;
}

// ---- block kind detection ----

function detectKind(lines) {
  const cleaned = lines
    .filter(l => l.trim() !== '')
    .filter(l => !/^#{3,}\s/.test(l));  // skip H3+ subheadings as classification cues

  if (cleaned.length === 0) return 'empty';

  const counts = {
    bullet: 0,
    numbered: 0,
    table: 0,
    blockquote: 0,
    defList: 0,    // **term**: description
    paragraph: 0,
  };

  let inCodeBlock = false;
  for (const raw of cleaned) {
    const line = raw.trim();
    if (line.startsWith('```')) { inCodeBlock = !inCodeBlock; continue; }
    if (inCodeBlock) continue;

    if (/^[-*]\s+/.test(line))              counts.bullet++;
    else if (/^\d+\.\s+/.test(line))        counts.numbered++;
    else if (line.startsWith('|') && line.endsWith('|') && line.includes('|', 1)) counts.table++;
    else if (line.startsWith('>'))          counts.blockquote++;
    else if (/^\*\*[^*]{2,40}\*\*[::]/.test(line)) counts.defList++;
    else                                    counts.paragraph++;
  }

  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  if (total === 0) return 'empty';

  const sorted = Object.entries(counts).sort((a, b) => b[1] - a[1]);
  const [topKind, topCount] = sorted[0];
  const ratio = topCount / total;

  // Need ≥60% dominance to commit; else mixed.
  if (ratio < 0.6) return 'mixed';

  return ({
    bullet: 'bullet-list',
    numbered: 'numbered-list',
    table: 'table',
    blockquote: 'blockquote-list',
    defList: 'definition-list',
    paragraph: 'paragraph',
  })[topKind];
}

// ---- formatting ----

function fmtKindDist(kinds) {
  const total = Object.values(kinds).reduce((a, b) => a + b, 0);
  return Object.entries(kinds)
    .sort((a, b) => b[1] - a[1])
    .map(([k, n]) => `${k}:${n}(${Math.round(n / total * 100)}%)`)
    .join(' · ');
}

function fmtReport(byType, totalsByType) {
  const lines = [];
  lines.push('# qua-vault body audit');
  lines.push('');
  lines.push(`Generated: ${new Date().toISOString()}`);
  lines.push('');
  lines.push('扫描每个文件的 `## H2` 标题及其下方 block 形状,聚合 per type 统计。');
  lines.push('block 形状要 ≥60% 占比才归类,否则 `mixed`。');
  lines.push('');

  const TYPES = ['author', 'book', 'chapter', 'paper'];
  for (const t of TYPES) {
    const total = totalsByType[t] || 0;
    const sections = byType[t] || new Map();
    lines.push(`## \`${t}\` — ${total} 个文件,${sections.size} 种不同 H2 标题`);
    lines.push('');

    // Top H2 headings.
    const ranked = [...sections.entries()].sort((a, b) => b[1].count - a[1].count);

    lines.push('### 前 30 个高频 H2(频率 / 覆盖率 / 形状分布)');
    lines.push('');
    lines.push('| H2 标题 | 出现次数 | 覆盖率 | 主导形状 | 形状分布 |');
    lines.push('|---|---:|---:|---|---|');
    for (const [h2, info] of ranked.slice(0, 30)) {
      const coverage = total > 0 ? `${Math.round(info.count / total * 100)}%` : '–';
      const dominant = Object.entries(info.kinds).sort((a, b) => b[1] - a[1])[0]?.[0] || '–';
      const dist = fmtKindDist(info.kinds);
      lines.push(`| ${h2.replace(/\|/g, '\\|')} | ${info.count} | ${coverage} | **${dominant}** | ${dist} |`);
    }
    lines.push('');

    // Long tail summary.
    if (ranked.length > 30) {
      const tail = ranked.slice(30);
      const tailSum = tail.reduce((s, [, info]) => s + info.count, 0);
      lines.push(`(长尾:剩余 ${tail.length} 个 H2 标题,合计 ${tailSum} 次出现 — 大概率是 LLM 漂移/同义变体,迁移时合并或删除)`);
      lines.push('');
    }
  }

  // Drift analysis: similar headings.
  lines.push('## 漂移嫌疑(肉眼看 top H2 列表里有没有同义不同名)');
  lines.push('');
  lines.push('建议人工 review 上述每个 type 的 top 30,把语义重复的合并。例:');
  lines.push('- `核心论点` / `主要论点` / `核心观点` / `核心论证`');
  lines.push('- `关键概念` / `主要概念` / `核心概念`');
  lines.push('- `重要引用` / `重要段落` / `关键引文`');
  lines.push('');
  lines.push('合并清单将进入 SPEC v0.2 的 BodySchema 起草阶段。');

  return lines.join('\n');
}

// ---- main ----

(async () => {
  console.log('scanning', VAULT);
  const files = await walk(VAULT);
  console.log(`found ${files.length} md files`);

  const byType = {};         // type -> Map<h2, { count, kinds: {kind: n} }>
  const totalsByType = {};   // type -> total file count

  let processed = 0;
  for (const f of files) {
    const text = await readFile(f, 'utf8');
    const { type, body } = extractTypeAndBody(text);
    if (!type) continue;

    totalsByType[type] = (totalsByType[type] || 0) + 1;
    if (!byType[type]) byType[type] = new Map();

    const sections = extractH2Sections(body);
    for (const s of sections) {
      const kind = detectKind(s.lines);
      let entry = byType[type].get(s.heading);
      if (!entry) {
        entry = { count: 0, kinds: {} };
        byType[type].set(s.heading, entry);
      }
      entry.count++;
      entry.kinds[kind] = (entry.kinds[kind] || 0) + 1;
    }
    processed++;
  }

  await mkdir(OUT, { recursive: true });
  const report = fmtReport(byType, totalsByType);
  await writeFile(REPORT, report);

  console.log('\nprocessed', processed, 'typed files');
  for (const t of ['author', 'book', 'chapter', 'paper']) {
    const total = totalsByType[t] || 0;
    const headings = byType[t]?.size || 0;
    console.log(`  ${t.padEnd(8)} ${String(total).padStart(6)} files · ${String(headings).padStart(4)} unique H2 headings`);
  }
  console.log(`\nfull report → ${path.relative(ROOT, REPORT)}`);
})();
