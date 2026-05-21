import { useMemo } from 'preact/hooks';
import type { Entry, EntryType } from '../types';

interface Props {
  type: EntryType;
  typeEntries: Entry[];
  onThemeClick: (theme: string) => void;
  onOpen: (entry: Entry) => void;
}

function fmtDate(ms?: number | null): string {
  if (!ms) return '';
  const d = new Date(ms);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

// The total count lives in the list header and a corpus-wide average rating
// isn't actionable, so the dashboard keeps two navigational blocks — frequent
// themes and recently-ingested items — packed into a compact two-column band.
export function Dashboard({ typeEntries, onThemeClick, onOpen }: Props) {
  const stats = useMemo(() => {
    const total = typeEntries.length;
    const recent = [...typeEntries]
      .sort((a, b) => (b.added || 0) - (a.added || 0))
      .slice(0, 6);
    const counts = new Map<string, number>();
    for (const e of typeEntries) for (const th of (e.themes ?? [])) {
      counts.set(th, (counts.get(th) ?? 0) + 1);
    }
    const topThemes = [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 18);
    return { total, recent, topThemes };
  }, [typeEntries]);

  if (stats.total === 0) return null;

  const hasThemes = stats.topThemes.length > 0;
  const hasRecent = stats.recent.length > 0 && !!stats.recent[0].added;
  if (!hasThemes && !hasRecent) return null;

  return (
    <section class={`mb-6 grid grid-cols-1 gap-5 ${hasThemes && hasRecent ? 'lg:grid-cols-[1fr_360px]' : ''}`}>
      {hasThemes && (
        <div class="min-w-0">
          <div class="text-[11px] uppercase tracking-wider text-muted font-medium mb-2">高频主题</div>
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

      {hasRecent && (
        <div class={`min-w-0 ${hasThemes ? 'border-t lg:border-t-0 lg:border-l border-base lg:pl-5 pt-3 lg:pt-0' : ''}`}>
          <div class="text-[11px] uppercase tracking-wider text-muted font-medium mb-2">近期入库</div>
          <div class="grid grid-cols-2 gap-x-4 gap-y-0.5">
            {stats.recent.map(e => (
              <button
                key={e.path}
                onClick={() => onOpen(e)}
                class="text-left flex items-baseline gap-2 px-1.5 py-0.5 rounded hover:bg-surface-2 transition min-w-0"
              >
                <span class="text-primary text-[12px] line-clamp-1 min-w-0 flex-1">{e.title}</span>
                <span class="text-muted text-[10px] tabular-nums shrink-0">{fmtDate(e.added)}</span>
              </button>
            ))}
          </div>
        </div>
      )}
    </section>
  );
}
