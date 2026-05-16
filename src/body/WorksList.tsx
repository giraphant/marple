import { useMemo } from 'preact/hooks';
import type { JSX } from 'preact';
import { marked } from 'marked';
import type { Entry } from '../types';
import { resolveWikilinks } from '../wiki';

/**
 * `## 代表著作` (author profile) — paragraph-per-book, each starting with a
 * wikilink to the book overview and a parenthesised year, followed by prose:
 *
 *   [[bennett-the-birth-of-the-2022/00-overview|The Birth of the Museum]]（1995 初版，2022 再版）是 Bennett 最具影响力…
 *   [[bennett-culture-1998/00-overview|Culture: A Reformer's Science]]（1998）是 Bennett 对文化研究…
 *
 * The wikilink target identifies the book entry; the parenthesised text is
 * the year (or year range / edition note). We render each as a card with
 * clickable title, year chip, and the description prose. Rating stars are
 * lifted from the linked entry when we can resolve it.
 */

const ITEM_RE = /^\[\[([^\]|\n]+?)(?:\|([^\]\n]+?))?\]\][（(]([^)）]+)[)）][\s,，。：:是为]*([\s\S]*)$/;

interface WorkItem {
  /** Wiki target path (e.g. `bennett-culture-1998/00-overview`). */
  target: string;
  /** Display label, falls back to last path segment. */
  label: string;
  /** Year / edition string captured from the parentheses after the wikilink. */
  year: string;
  /** Prose description after the year. */
  description: string;
  /** Resolved vault entry if the wikilink points at one. */
  entry: Entry | null;
}

function parseWorks(content: string, wikiIndex: Map<string, Entry>): WorkItem[] {
  // Paragraphs are separated by blank lines.
  const paragraphs = content.split(/\n{2,}/).map(p => p.trim()).filter(Boolean);
  const items: WorkItem[] = [];
  for (const p of paragraphs) {
    const m = p.match(ITEM_RE);
    if (!m) continue;
    const target = m[1].trim();
    const label = (m[2] ?? target.split('/').pop() ?? target).trim();
    const baseTarget = target.split('#')[0];
    const entry = wikiIndex.get(baseTarget) || wikiIndex.get(baseTarget.toLowerCase()) || null;
    items.push({
      target,
      label,
      year: m[3].trim(),
      description: m[4].trim(),
      entry,
    });
  }
  return items;
}

interface Props {
  content: string;
  wikiIndex: Map<string, Entry>;
  onWikiClick: (path: string, modifiers: { meta: boolean }) => void;
}

export function WorksList({ content, wikiIndex, onWikiClick }: Props) {
  const items = useMemo(() => parseWorks(content, wikiIndex), [content, wikiIndex]);

  if (items.length === 0) {
    return <Marked content={content} wikiIndex={wikiIndex} />;
  }

  return (
    <ol class="!pl-0 list-none my-3 space-y-2.5 [&>li]:my-0">
      {items.map((it) => (
        <WorkCard key={it.target} item={it} wikiIndex={wikiIndex} onClick={onWikiClick} />
      ))}
    </ol>
  );
}

function WorkCard({ item, wikiIndex, onClick }: {
  item: WorkItem;
  wikiIndex: Map<string, Entry>;
  onClick: (path: string, modifiers: { meta: boolean }) => void;
}) {
  const rating = item.entry?.rating_score;
  const descriptionHtml = useMemo(
    () => marked.parse(resolveWikilinks(item.description, wikiIndex)) as string,
    [item.description, wikiIndex],
  );

  const onTitleClick = (e: MouseEvent) => {
    if (!item.entry) return;
    e.preventDefault();
    onClick(item.entry.path, { meta: e.metaKey || e.ctrlKey });
  };

  return (
    <li class="group rounded-md border border-base bg-surface px-4 py-3 hover:border-strong transition">
      <div class="flex items-baseline gap-2 flex-wrap">
        {item.entry
          ? (
            <a
              href="#"
              onClick={onTitleClick as unknown as JSX.MouseEventHandler<HTMLAnchorElement>}
              class="text-[14px] font-semibold text-primary hover:text-amber-700 dark:hover:text-amber-300 transition leading-snug"
            >
              {item.label}
            </a>
          )
          : (
            <span class="text-[14px] font-semibold text-primary leading-snug">{item.label}</span>
          )
        }
        <span class="text-[11px] tabular-nums text-secondary bg-page border border-base rounded px-1.5 py-0.5 whitespace-nowrap">
          {item.year}
        </span>
        {rating && rating > 0 && (
          <span class="text-[11px] text-amber-600 dark:text-amber-400 tabular-nums whitespace-nowrap" title={`${rating} 星`}>
            {'★'.repeat(rating)}
          </span>
        )}
      </div>
      {item.description && (
        <div
          class="mt-1.5 text-[13px] text-secondary leading-relaxed [&_p]:my-1 [&_p:first-child]:mt-0"
          dangerouslySetInnerHTML={{ __html: descriptionHtml }}
        />
      )}
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

export function isWorksH2(title: string): boolean {
  const t = title.trim();
  return /^代表著作$/.test(t) || /^主要著作$/.test(t) || /^代表作品$/.test(t);
}
