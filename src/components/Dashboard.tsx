import { useMemo } from 'preact/hooks';
import type { Entry, EntryType } from '../types';

interface Props {
  type: EntryType;
  typeEntries: Entry[];
  onThemeClick: (theme: string) => void;
  onOpen: (entry: Entry) => void;
}

// The total count lives in the list header and a corpus-wide average rating
// isn't actionable, so the dashboard keeps only the two navigational blocks —
// frequent themes and top picks — packed into a compact two-column band.
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
    <section class={`mb-5 bg-surface border border-base rounded-2xl shadow-soft p-5 grid grid-cols-1 gap-5 ${hasThemes && hasTop ? 'lg:grid-cols-[1fr_360px]' : ''}`}>
      {hasThemes && (
        <div class="min-w-0">
          <div class="text-[11px] uppercase tracking-wider text-muted font-semibold mb-2">高频主题</div>
          <div class="flex flex-wrap gap-1.5">
            {stats.topThemes.map(([th, n]) => (
              <button
                key={th}
                onClick={() => onThemeClick(th)}
                class="text-[10.5px] px-2 py-0.5 rounded border border-base bg-page text-primary hover:bg-accent-bg hover:border-accent hover:text-accent-text transition"
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
          <div class="grid grid-cols-2 gap-x-4 gap-y-0.5">
            {stats.top.map(e => (
              <button
                key={e.path}
                onClick={() => onOpen(e)}
                class="text-left flex items-center gap-1.5 px-1.5 py-0.5 rounded hover:bg-surface-2 transition min-w-0"
              >
                {e.rating && <span class="text-star text-[10px] shrink-0 tabular-nums">{e.rating}</span>}
                <span class="text-primary text-[12px] line-clamp-1 min-w-0">{e.title}</span>
              </button>
            ))}
          </div>
        </div>
      )}
    </section>
  );
}
