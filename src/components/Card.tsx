import { useRef, useState, useLayoutEffect } from 'preact/hooks';
import type { Entry } from '../types';
import { splitAuthors } from '../wiki';

/** The preview is raw analysis-doc text and may still carry inline markdown.
 *  Strip the common markers so the card shows clean prose. */
function plainPreview(s: string): string {
  return s
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/(\*\*|__)(.*?)\1/g, '$2')
    .replace(/(\*|_)(.*?)\1/g, '$2')
    .replace(/^>\s?/gm, '')
    .replace(/^[-*+]\s+/gm, '')
    .replace(/\s+/g, ' ')
    .trim();
}

/** Theme chips kept to a single line: render only as many as fit the card
 *  width, collapse the rest into a "+N". Widths are measured once (chip text is
 *  static) and the fit is recomputed on resize. */
function ThemeChips({ themes, onThemeClick }: { themes: string[]; onThemeClick?: (t: string) => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const widths = useRef<number[]>([]);
  const [count, setCount] = useState(themes.length);
  const themesKey = themes.join('');

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const chipEls = Array.from(el.querySelectorAll<HTMLElement>('[data-chip]'));
    if (chipEls.length === themes.length) {
      widths.current = chipEls.map(c => c.offsetWidth);
    }
    const fit = (avail: number) => {
      const gap = 6;
      const badge = 30; // reserved width for the "+N" marker
      let used = 0;
      for (let i = 0; i < widths.current.length; i++) {
        used += (i > 0 ? gap : 0) + widths.current[i];
        const moreAfter = i < widths.current.length - 1;
        if (used + (moreAfter ? gap + badge : 0) > avail) return i;
      }
      return widths.current.length;
    };
    const apply = () => setCount(fit(el.clientWidth));
    apply();
    const ro = new ResizeObserver(apply);
    ro.observe(el);
    return () => ro.disconnect();
  }, [themesKey]); // eslint-disable-line react-hooks/exhaustive-deps

  const shown = themes.slice(0, count);
  const extra = themes.length - shown.length;
  return (
    <div ref={ref} class="flex flex-nowrap items-center gap-1.5 pt-2.5 border-t border-base overflow-hidden">
      {shown.map(th => (
        <button
          data-chip
          key={th}
          onClick={(ev: MouseEvent) => { ev.stopPropagation(); onThemeClick?.(th); }}
          class="shrink-0 whitespace-nowrap text-[10.5px] px-2 py-0.5 bg-page text-secondary rounded-md hover:bg-accent-bg hover:text-accent-text transition"
          title={`按主题筛选：${th}`}
        >{th}</button>
      ))}
      {extra > 0 && <span class="shrink-0 text-[10.5px] text-muted self-center">+{extra}</span>}
    </div>
  );
}

interface Props {
  entry: Entry;
  /** Receives the entry and the mouse event so callers can read modifier keys
   *  (e.g. Cmd/Ctrl to open in a new tab). */
  onClick: (entry: Entry, ev: MouseEvent) => void;
  /** Click a theme chip to filter by it (stops the card's open-on-click). */
  onThemeClick?: (theme: string) => void;
  /** Click an author name to filter by it (stops the card's open-on-click). */
  onAuthorClick?: (author: string) => void;
}

export function Card({ entry, onClick, onThemeClick, onAuthorClick }: Props) {
  const themes = entry.themes ?? [];
  const authors = splitAuthors(entry.author);
  const fallbackTitle = entry.path.split('/').pop()!.replace(/\.md$/, '');
  const preview = entry.preview ? plainPreview(entry.preview) : '';
  // Preview is the real scan target (titles are often uninformative), so show
  // more of it, and size it to the analysis depth: longer body → more lines →
  // taller card, making the masonry height a legible "how much is here" signal.
  const previewLines = Math.max(3, Math.min(12, Math.round(((entry.body_len ?? 0) - 1000) / 1500) + 3));
  return (
    <div
      class="card bg-surface border border-base rounded-2xl p-5 shadow-soft hover:shadow-soft-lg hover:-translate-y-0.5 active:translate-y-0 active:shadow-soft cursor-pointer flex flex-col gap-2.5 transition"
      onClick={(ev: MouseEvent) => onClick(entry, ev)}
    >
      <div class="flex flex-col gap-1">
        {(entry.author || entry.year || entry.rating) && (
          <div class="flex items-baseline justify-between gap-2 text-[11px]">
            <div class="min-w-0 line-clamp-1">
              {authors.map((a, i) => (
                <span key={a + i}>
                  {i > 0 ? <span class="text-muted">, </span> : null}
                  <span
                    onClick={(ev: MouseEvent) => { ev.stopPropagation(); onAuthorClick?.(a); }}
                    class="font-medium text-secondary hover:text-accent-text cursor-pointer transition"
                    title={`按作者筛选：${a}`}
                  >{a}</span>
                </span>
              ))}
              {entry.author && entry.year ? <span class="text-muted"> · </span> : null}
              {entry.year && <span class="text-secondary tabular-nums">{entry.year}</span>}
            </div>
            {entry.rating && <span class="shrink-0 text-star tabular-nums">{entry.rating}</span>}
          </div>
        )}
        <div class="font-semibold text-[15px] leading-snug line-clamp-2 text-primary tracking-[-0.01em]">
          {entry.title || fallbackTitle}
        </div>
      </div>

      {preview && (
        <div
          class="text-[12.5px] text-secondary leading-relaxed overflow-hidden"
          style={{ display: '-webkit-box', WebkitBoxOrient: 'vertical', WebkitLineClamp: String(previewLines) }}
        >{preview}</div>
      )}

      {themes.length > 0 && <ThemeChips themes={themes} onThemeClick={onThemeClick} />}
    </div>
  );
}
