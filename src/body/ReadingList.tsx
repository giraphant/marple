import { useMemo } from 'preact/hooks';
import { marked } from 'marked';
import type { Entry } from '../types';
import { resolveWikilinks } from '../wiki';

/**
 * `## 推荐精读章节` (book overview) — numbered list of recommended chapters,
 * each item shaped as:
 *
 *   1. **ch05 Culture: A Reformer's Science** —— 全书核心命题的理论阐述。…
 *   2. **第8章（糖尿病患者的具身化与能动性）** — 相关性最高（三星）。…
 *
 * The title in **bold** carries the chapter reference. The trailing prose
 * (after `—` / `——`) explains why this chapter matters. We render each as
 * a card with a numbered badge that doubles as a visual priority cue
 * (#1 reads as "read this first").
 *
 * The numbering inside the rendered cards comes from the source order
 * (matches the author's intent), not from a re-counted index.
 */

interface ReadingItem {
  index: number;
  title: string;       // text inside the **...** (or whole item title if no bold)
  description: string; // remainder after the separator
}

// Match a list item like: "1. **TITLE** — description"
//                        "2. **TITLE** —— description"
// Title is captured by group 2; description (which may span multiple lines) is group 3.
// Allow plain `-` as well so we don't miss items typed with ASCII hyphens.
const ITEM_RE = /^(\d+)\.\s+\*\*([^*\n]+?)\*\*\s*(?:[—–\-]+)\s*([\s\S]+)$/;
// Fallback for items without a separator: "1. **TITLE**"
const TITLE_ONLY_RE = /^(\d+)\.\s+\*\*([^*\n]+?)\*\*\s*([\s\S]*)$/;
// Even more lenient: "1. plain text title (no bold marker)"
const BARE_RE = /^(\d+)\.\s+(.+)$/s;

function parseReadingList(content: string): ReadingItem[] {
  // Group lines into items. An item starts with `\d+. `. Continuation lines
  // (blank or indented or just bare text after the first line) belong to the
  // previous item until we hit the next `\d+. `.
  const lines = content.split(/\r?\n/);
  const chunks: string[] = [];
  let buf: string[] = [];

  const flush = () => {
    const text = buf.join('\n').trim();
    if (text) chunks.push(text);
    buf = [];
  };
  for (const line of lines) {
    if (/^\d+\.\s+/.test(line)) {
      flush();
    }
    buf.push(line);
  }
  flush();

  const items: ReadingItem[] = [];
  for (const c of chunks) {
    let m = c.match(ITEM_RE);
    if (m) {
      items.push({ index: parseInt(m[1], 10), title: m[2].trim(), description: m[3].trim() });
      continue;
    }
    m = c.match(TITLE_ONLY_RE);
    if (m) {
      items.push({ index: parseInt(m[1], 10), title: m[2].trim(), description: m[3].trim() });
      continue;
    }
    m = c.match(BARE_RE);
    if (m) {
      items.push({ index: parseInt(m[1], 10), title: m[2].trim(), description: '' });
    }
  }
  return items;
}

interface Props {
  content: string;
  wikiIndex: Map<string, Entry>;
}

export function ReadingList({ content, wikiIndex }: Props) {
  const items = useMemo(() => parseReadingList(content), [content]);

  if (items.length === 0) {
    // Couldn't parse — fall back to plain markdown.
    return <Marked content={content} wikiIndex={wikiIndex} />;
  }

  return (
    <ol class="!pl-0 list-none my-3 space-y-2 [&>li]:my-0">
      {items.map((it) => (
        <li key={it.index} class="flex items-start gap-3 rounded-xl border border-base bg-surface shadow-soft px-4 py-3 hover:shadow-soft-lg transition">
          <span
            class="shrink-0 inline-flex items-center justify-center w-6 h-6 rounded-full bg-accent-bg text-accent-text text-[12px] font-semibold tabular-nums mt-0.5"
            aria-hidden="true"
          >
            {it.index}
          </span>
          <div class="flex-1 min-w-0">
            <div class="text-[14px] font-semibold text-primary leading-snug">
              <span dangerouslySetInnerHTML={{ __html: renderInline(it.title, wikiIndex) }} />
            </div>
            {it.description && (
              <div class="mt-1 text-[13px] text-secondary leading-relaxed [&_p]:my-0">
                <Marked content={it.description} wikiIndex={wikiIndex} />
              </div>
            )}
          </div>
        </li>
      ))}
    </ol>
  );
}

function renderInline(raw: string, wikiIndex: Map<string, Entry>): string {
  return marked.parseInline(resolveWikilinks(raw, wikiIndex)) as string;
}

function Marked({ content, wikiIndex }: { content: string; wikiIndex: Map<string, Entry> }) {
  const html = useMemo(
    () => marked.parse(resolveWikilinks(content, wikiIndex)) as string,
    [content, wikiIndex],
  );
  return <div dangerouslySetInnerHTML={{ __html: html }} />;
}

export function isReadingListH2(title: string): boolean {
  const t = title.trim();
  return /^推荐精读章节$/.test(t) || /^精读章节$/.test(t) || /^精读推荐$/.test(t);
}
