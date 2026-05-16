import { useMemo, useState } from 'preact/hooks';
import { marked } from 'marked';
import type { Entry } from '../types';
import { resolveWikilinks } from '../wiki';

/**
 * Quote-cards renderer.
 *
 * Targets `## 可引用观点` / `## 金句要点` / `## 可引用段落` H2 sections.
 * Per SPEC §4.5 these are typed as `blockquote-list` (paper) or
 * `numbered-list` (author 可引用观点). Items follow a consistent shape:
 *
 *   - "QUOTE..." (*Source Title*, chN)
 *   - "QUOTE..." 引 Foo (*Source*, p.42)
 *
 * The renderer extracts (quote, source) from each item and renders a
 * vertical stack of cards. Each card has a copy-to-clipboard action that
 * yields "QUOTE\n— SOURCE" — directly drop-into-draft material.
 */

interface QuoteItem {
  /** The full text of one list item (may include attribution). */
  raw: string;
  /** Extracted quote portion (no surrounding quotes). */
  quote: string | null;
  /** Trailing parenthetical source like "*Nightwork*, ch11". */
  source: string | null;
  /** Optional attribution prefix like "引 Serizawa Shunsuke". */
  attribution: string | null;
}

const QUOTE_RE = /[""""「『]([^""」』]+)[""""」』]/;
const SOURCE_TRAIL_RE = /[（(]([^）)]+)[）)]\s*$/;
// "引 …" / "—Bersani" / "by Foo" — informal attribution prefixes.
const ATTRIBUTION_RE = /(?:^|\s)引\s+([^（(\n]+?)(?=\s*[（(]|$)/;

/** Parse a single list item ("- foo" or "1. foo") into a structured quote. */
function parseQuoteItem(raw: string): QuoteItem {
  const stripped = raw.replace(/^\s*(?:[-*+]|\d+\.)\s+/, '').trim();
  const quoteMatch = stripped.match(QUOTE_RE);
  const sourceMatch = stripped.match(SOURCE_TRAIL_RE);
  const attrMatch = stripped.match(ATTRIBUTION_RE);
  return {
    raw: stripped,
    quote: quoteMatch ? quoteMatch[1].trim() : null,
    source: sourceMatch ? sourceMatch[1].trim() : null,
    attribution: attrMatch ? attrMatch[1].trim() : null,
  };
}

/** Split a section's content into list items. Handles bullet lists,
 *  numbered lists, and blockquote-style lists. */
function splitListItems(content: string): string[] {
  const lines = content.split(/\r?\n/);
  const items: string[] = [];
  let buf: string[] = [];
  const flush = () => { if (buf.length) { items.push(buf.join('\n').trim()); buf = []; } };

  for (const line of lines) {
    if (/^\s*(?:[-*+]|\d+\.)\s+/.test(line) || /^\s*>\s+/.test(line)) {
      flush();
      buf.push(line.replace(/^\s*>\s+/, ''));         // normalize blockquote marker
    } else if (/^\s+\S/.test(line) && buf.length > 0) {
      buf.push(line);                                  // continuation of current item
    } else if (line.trim() === '') {
      flush();
    } else {
      // Loose paragraph line outside any list — push as its own item.
      flush();
      buf.push(line);
    }
  }
  flush();
  return items.filter(Boolean);
}

interface Props {
  content: string;
  wikiIndex: Map<string, Entry>;
}

export function QuoteCards({ content, wikiIndex }: Props) {
  const items = useMemo(() => splitListItems(content).map(parseQuoteItem), [content]);

  if (items.length === 0) {
    // Fallback: render whole section through marked.
    return <FallbackMarked content={content} wikiIndex={wikiIndex} />;
  }

  return (
    <div class="my-3 space-y-2">
      {items.map((it, i) => <QuoteCard key={i} item={it} wikiIndex={wikiIndex} />)}
    </div>
  );
}

function QuoteCard({ item, wikiIndex }: { item: QuoteItem; wikiIndex: Map<string, Entry> }) {
  const [copied, setCopied] = useState(false);

  const quoteHtml = useMemo(() => {
    const text = item.quote ?? item.raw;
    return marked.parseInline(resolveWikilinks(text, wikiIndex)) as string;
  }, [item, wikiIndex]);
  const sourceHtml = useMemo(() => {
    if (!item.source) return '';
    return marked.parseInline(resolveWikilinks(item.source, wikiIndex)) as string;
  }, [item.source, wikiIndex]);

  const copy = async () => {
    // Build a plain-text version suitable for pasting into a draft.
    const q = item.quote ?? item.raw;
    const src = item.source ? ` — ${item.source.replace(/\*/g, '')}` : '';
    try {
      await navigator.clipboard.writeText(`"${q}"${src}`);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch { /* ignore */ }
  };

  return (
    <figure class="group relative rounded-md bg-rose-50/40 dark:bg-rose-950/20 border-l-4 border-rose-300 dark:border-rose-700 pl-4 pr-3 py-3">
      {/* `!border-l-0 !pl-0 !my-0` strips .prose-body's default 3-px blockquote
          frame so we don't get a double left bar inside the figure's pink
          frame. font-family puts Georgia/Charter first so English uses a
          proper English serif at full size; Songti picks up the CJK glyphs
          via per-glyph fallback. */}
      <blockquote
        class="!border-l-0 !pl-0 !my-0 text-[15.5px] leading-relaxed text-primary"
        style={{ fontFamily: 'Georgia, "Iowan Old Style", "Charter", "Songti SC", "STSong", serif' }}
        dangerouslySetInnerHTML={{ __html: quoteHtml }}
      />
      {(item.source || item.attribution) && (
        <figcaption class="mt-1.5 flex items-center gap-2 text-[11px] text-secondary">
          {item.attribution && (
            <span class="text-muted">引 {item.attribution}</span>
          )}
          {item.source && (
            <span
              class="inline-block px-1.5 py-0.5 rounded bg-rose-100 dark:bg-rose-950/40 text-rose-800 dark:text-rose-300 border border-rose-200 dark:border-rose-900"
              dangerouslySetInnerHTML={{ __html: sourceHtml }}
            />
          )}
        </figcaption>
      )}
      <button
        onClick={copy}
        title="复制引文（含来源）"
        class="absolute top-2 right-2 text-[10px] px-1.5 py-0.5 rounded border border-base bg-surface text-muted hover:text-primary hover:border-strong opacity-0 group-hover:opacity-100 transition"
      >
        {copied ? '✓ 已复制' : '复制'}
      </button>
    </figure>
  );
}

function FallbackMarked({ content, wikiIndex }: { content: string; wikiIndex: Map<string, Entry> }) {
  const html = useMemo(
    () => marked.parse(resolveWikilinks(content, wikiIndex)) as string,
    [content, wikiIndex],
  );
  return <div dangerouslySetInnerHTML={{ __html: html }} />;
}

export function isQuoteH2(title: string): boolean {
  return /^(可引用观点|金句要点|可引用段落|可引段落|金句|关键引文|代表性引文)$/i.test(title.trim());
}
