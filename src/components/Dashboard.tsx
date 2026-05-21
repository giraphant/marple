import { useMemo } from 'preact/hooks';
import type { Entry, EntryType } from '../types';
import { MiniRow } from './MiniRow';

interface Props {
  type: EntryType;
  typeEntries: Entry[];
  onThemeClick: (theme: string) => void;
  onOpen: (entry: Entry) => void;
}

// The total count lives in the list header and the average rating across a whole
// corpus isn't actionable, so the dashboard drops the vanity stat column and
// keeps only the two navigational blocks: frequent themes and top picks.
export function Dashboard({ typeEntries, onThemeClick, onOpen }: Props) {
  const stats = useMemo(() => {
    const total = typeEntries.length;
    const top = [...typeEntries]
      .sort((a, b) => (b.rating_score || 0) - (a.rating_score || 0))
      .slice(0, 6);
    const counts = new Map<string, number>();
    for (const e of typeEntries) for (const th of (e.themes ?? [])) {
      counts.set(th, (counts.get(th) ?? 0) + 1);
    }
    const topThemes = [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 18);
    return { total, top, topThemes };
  }, [typeEntries]);

  if (stats.total === 0) return null;

  const hasThemes = stats.topThemes.length > 0;
  const hasTop = stats.top.length > 0 && stats.top[0].rating_score > 0;
  if (!hasThemes && !hasTop) return null;

  return (
    <section
      class={`mb-5 bg-surface border border-base rounded-2xl shadow-soft p-5 grid grid-cols-1 gap-5 ${
        hasThemes && hasTop ? 'lg:grid-cols-[1fr_320px]' : ''
      }`}
    >
      {hasThemes && (
        <div class="min-w-0">
          <div class="text-[11px] uppercase tracking-wider text-muted font-semibold mb-2">高频主题</div>
          <div class="flex flex-wrap gap-1.5">
            {stats.topThemes.map(([th, n]) => (
              <button
                key={th}
                onClick={() => onThemeClick(th)}
                class="text-[11px] px-2 py-0.5 rounded border border-base bg-page text-primary hover:bg-accent-bg hover:border-accent hover:text-accent-text transition"
              >
                {th} <span class="text-muted tabular-nums">{n}</span>
              </button>
            ))}
          </div>
        </div>
      )}

      {hasTop && (
        <div class={`min-w-0 ${hasThemes ? 'border-t lg:border-t-0 lg:border-l border-base lg:pl-5 pt-3 lg:pt-0' : ''}`}>
          <div class="text-[11px] uppercase tracking-wider text-muted font-semibold mb-2">高分推荐</div>
          <div class="space-y-0.5">
            {stats.top.map(e => <MiniRow entry={e} onClick={onOpen} key={e.path} />)}
          </div>
        </div>
      )}
    </section>
  );
}
