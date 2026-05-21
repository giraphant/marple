import { useMemo } from 'preact/hooks';
import type { Entry, EntryType } from '../types';
import { TYPE_BY_ID } from '../types';
import { MiniRow } from './MiniRow';

interface Props {
  type: EntryType;
  typeEntries: Entry[];
  onThemeClick: (theme: string) => void;
  onOpen: (entry: Entry) => void;
}

export function Dashboard({ type, typeEntries, onThemeClick, onOpen }: Props) {
  const stats = useMemo(() => {
    const total = typeEntries.length;
    const rated = typeEntries.filter(e => e.rating_score > 0);
    const avg = rated.length ? rated.reduce((s, e) => s + e.rating_score, 0) / rated.length : 0;
    const top = [...typeEntries]
      .sort((a, b) => (b.rating_score || 0) - (a.rating_score || 0))
      .slice(0, 6);
    const counts = new Map<string, number>();
    for (const e of typeEntries) for (const th of (e.themes ?? [])) {
      counts.set(th, (counts.get(th) ?? 0) + 1);
    }
    const topThemes = [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 18);
    return { total, avg, top, topThemes };
  }, [typeEntries]);

  if (stats.total === 0) return null;

  const typeMeta = TYPE_BY_ID[type] ?? { label: type, accent: '' };

  return (
    <section class="mb-5 bg-surface border border-base rounded-2xl shadow-soft p-5 grid grid-cols-1 lg:grid-cols-[260px_1fr_320px] gap-5">
      <div class="space-y-1.5">
        <div class="text-[11px] uppercase tracking-wider text-muted font-semibold">{typeMeta.label}</div>
        <div class="text-2xl font-semibold tabular-nums">{stats.total}</div>
        {stats.avg > 0 && (
          <div class="text-[12px] text-secondary">
            平均评分 <span class="text-star">{'★'.repeat(Math.round(stats.avg))}</span>
            <span class="text-muted tabular-nums"> ({stats.avg.toFixed(2)})</span>
          </div>
        )}
        <div class="text-[12px] text-secondary">{stats.topThemes.length} 个 themes</div>
      </div>

      {stats.topThemes.length > 0 && (
        <div class="min-w-0">
          <div class="text-[11px] uppercase tracking-wider text-muted font-semibold mb-2">高频主题</div>
          <div class="flex flex-wrap gap-1.5">
            {stats.topThemes.map(([th, n]) => (
              <button
                onClick={() => onThemeClick(th)}
                class="text-[11px] px-2 py-0.5 rounded border border-base bg-page text-primary hover:bg-accent-bg hover:border-accent hover:text-accent-text transition"
              >
                {th} <span class="text-muted tabular-nums">{n}</span>
              </button>
            ))}
          </div>
        </div>
      )}

      {stats.top.length > 0 && stats.top[0].rating_score > 0 && (
        <div class="min-w-0 border-t lg:border-t-0 lg:border-l border-base lg:pl-5 pt-3 lg:pt-0">
          <div class="text-[11px] uppercase tracking-wider text-muted font-semibold mb-2">高分推荐</div>
          <div class="space-y-0.5">
            {stats.top.map(e => <MiniRow entry={e} onClick={onOpen} key={e.path} />)}
          </div>
        </div>
      )}
    </section>
  );
}
