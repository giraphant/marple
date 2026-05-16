import { useMemo } from 'preact/hooks';
import type { JSX } from 'preact';
import { marked } from 'marked';
import type { Entry } from '../types';
import { resolveWikilinks } from '../wiki';

/**
 * `## 理论网络` (author profile) — bullet list of theorists this author is
 * in dialogue with. Each item follows the shape:
 *
 *   - Michel Foucault（治理术、权力/知识）——Bennett 最核心的理论资源…
 *   - Antonio Gramsci（霸权理论、伦理国家）——Bennett 的系统批判对象…
 *
 * We render each entry as a compact card: bold name, comma-split keywords
 * as amber chips, then the relationship prose on the next line. Names
 * wrapped in `[[wikilink]]` become clickable if the linked entry exists.
 */

const ITEM_RE = /^\s*[-*+]\s+([\s\S]+?)\s*[（(]([^)）]+)[)）]\s*[—–\-]+\s*([\s\S]+)$/;
const NAME_WIKILINK_RE = /^\[\[([^\]|\n]+?)(?:\|([^\]\n]+?))?\]\]\s*(.*)$/;

interface TheoryItem {
  /** Display name (may include a wikilink target). */
  name: string;
  /** Wiki target if the name was `[[…]]` — used to navigate via the SPA. */
  target: string | null;
  /** Resolved entry for the target, if any (lets us add rating/etc later). */
  entry: Entry | null;
  /** Comma-split keywords from the parenthesised tag group. */
  keywords: string[];
  /** Relationship-to-author prose after the em-dash. */
  description: string;
}

function parseTheoryItem(line: string, wikiIndex: Map<string, Entry>): TheoryItem | null {
  const m = line.match(ITEM_RE);
  if (!m) return null;

  let nameRaw = m[1].trim();
  let target: string | null = null;
  let entry: Entry | null = null;
  const wikiMatch = nameRaw.match(NAME_WIKILINK_RE);
  if (wikiMatch) {
    target = wikiMatch[1].trim();
    const label = (wikiMatch[2] ?? target.split('/').pop() ?? target).trim();
    const trailing = wikiMatch[3].trim();
    nameRaw = trailing ? `${label} ${trailing}` : label;
    const baseTarget = target.split('#')[0];
    entry = wikiIndex.get(baseTarget) || wikiIndex.get(baseTarget.toLowerCase()) || null;
  }

  const keywords = m[2]
    .split(/[,，、;；]/)
    .map(s => s.trim())
    .filter(Boolean);

  return {
    name: nameRaw,
    target,
    entry,
    keywords,
    description: m[3].trim(),
  };
}

function parseTheoryNetwork(content: string, wikiIndex: Map<string, Entry>): TheoryItem[] {
  // Split into list items; treat each bullet line + continuation lines as one item.
  const lines = content.split(/\r?\n/);
  const chunks: string[] = [];
  let buf: string[] = [];
  const flush = () => { const t = buf.join('\n').trim(); if (t) chunks.push(t); buf = []; };
  for (const line of lines) {
    if (/^\s*[-*+]\s+/.test(line)) {
      flush();
      buf.push(line);
    } else if (line.trim() === '') {
      flush();
    } else {
      buf.push(line);
    }
  }
  flush();

  const items: TheoryItem[] = [];
  for (const c of chunks) {
    const it = parseTheoryItem(c, wikiIndex);
    if (it) items.push(it);
  }
  return items;
}

interface Props {
  content: string;
  wikiIndex: Map<string, Entry>;
  onWikiClick: (path: string, modifiers: { meta: boolean }) => void;
}

export function TheoryNetwork({ content, wikiIndex, onWikiClick }: Props) {
  const items = useMemo(() => parseTheoryNetwork(content, wikiIndex), [content, wikiIndex]);

  if (items.length === 0) {
    return <Marked content={content} wikiIndex={wikiIndex} />;
  }

  return (
    <ul class="!pl-0 list-none my-3 space-y-1.5 [&>li]:my-0">
      {items.map((it, i) => (
        <TheoryRow key={i} item={it} wikiIndex={wikiIndex} onClick={onWikiClick} />
      ))}
    </ul>
  );
}

function TheoryRow({ item, wikiIndex, onClick }: {
  item: TheoryItem;
  wikiIndex: Map<string, Entry>;
  onClick: (path: string, modifiers: { meta: boolean }) => void;
}) {
  const descHtml = useMemo(
    () => marked.parseInline(resolveWikilinks(item.description, wikiIndex)) as string,
    [item.description, wikiIndex],
  );
  const onNameClick = (e: MouseEvent) => {
    if (!item.entry) return;
    e.preventDefault();
    onClick(item.entry.path, { meta: e.metaKey || e.ctrlKey });
  };

  return (
    <li class="px-3 py-2 rounded-md border border-base bg-surface hover:border-strong transition">
      <div class="flex flex-wrap items-center gap-1.5">
        {item.entry
          ? (
            <a
              href="#"
              onClick={onNameClick as unknown as JSX.MouseEventHandler<HTMLAnchorElement>}
              class="text-[14px] font-semibold text-primary hover:text-amber-700 dark:hover:text-amber-300 transition"
            >
              {item.name}
            </a>
          )
          : (
            <span class="text-[14px] font-semibold text-primary">{item.name}</span>
          )
        }
        {item.keywords.map((k, i) => (
          <span
            key={i}
            class="text-[11px] px-1.5 py-0.5 rounded bg-amber-50 dark:bg-amber-950/30 text-amber-800 dark:text-amber-300 border border-amber-200/60 dark:border-amber-900/60 leading-snug"
          >
            {k}
          </span>
        ))}
      </div>
      <div
        class="mt-1 text-[13px] text-secondary leading-relaxed"
        dangerouslySetInnerHTML={{ __html: descHtml }}
      />
    </li>
  );
}

function Marked({ content, wikiIndex }: { content: string; wikiIndex: Map<string, Entry> }) {
  const html = useMemo(
    () => marked.parse(resolveWikilinks(content, wikiIndex)) as string,
    [content, wikiIndex],
  );
  return <div dangerouslySetInnerHTML={{ __html: html }} />;
}

export function isTheoryNetworkH2(title: string): boolean {
  const t = title.trim();
  return /^理论网络$/.test(t) || /^思想网络$/.test(t) || /^理论谱系$/.test(t);
}
