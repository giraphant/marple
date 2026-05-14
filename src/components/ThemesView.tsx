import { useMemo, useState, useEffect } from 'preact/hooks';
import type { Entry, EntryType } from '../types';

interface Props {
  entries: Entry[];
  /** Apply this theme as a filter (also switches to the given list type if provided). */
  onThemeClick: (theme: string, fromType?: EntryType) => void;
}

interface ThemeRow {
  theme: string;
  total: number;
  /** Count per type for showing colored dots. */
  byType: Partial<Record<EntryType, number>>;
}

const TYPE_DOT: Record<EntryType, string> = {
  'paper-analysis':  'bg-amber-400',
  'book-overview':   'bg-emerald-400',
  'chapter-summary': 'bg-teal-400',
  'author-profile':  'bg-sky-400',
  'topic-synthesis': 'bg-violet-400',
  'note':            'bg-rose-400',
};

const TYPE_LABEL: Record<EntryType, string> = {
  'paper-analysis': '论文',
  'book-overview': '书',
  'chapter-summary': '章节',
  'author-profile': '作者',
  'topic-synthesis': '主题',
  'note': '笔记',
};

const INITIAL_LIMIT = 600;
const LOAD_STEP = 600;

export function ThemesView({ entries, onThemeClick }: Props) {
  const [rawQuery, setRawQuery] = useState('');
  const [query, setQuery] = useState('');
  // Default minCount=2 — the vault has ~12k themes that only appear once
  // (mostly typos / one-off LLM coinages); rendering them all is ~80k DOM
  // nodes and stalls the browser. Click "1" to see them anyway.
  const [minCount, setMinCount] = useState(2);
  const [limit, setLimit] = useState(INITIAL_LIMIT);

  // Debounce the query so each keystroke doesn't re-render the full grid.
  useEffect(() => {
    const id = window.setTimeout(() => setQuery(rawQuery), 150);
    return () => window.clearTimeout(id);
  }, [rawQuery]);

  // Reset pagination on filter change.
  useEffect(() => { setLimit(INITIAL_LIMIT); }, [query, minCount]);

  const rows = useMemo(() => {
    const map = new Map<string, ThemeRow>();
    for (const e of entries) {
      const themes = e.themes ?? [];
      for (const t of themes) {
        if (!t) continue;
        let row = map.get(t);
        if (!row) {
          row = { theme: t, total: 0, byType: {} };
          map.set(t, row);
        }
        row.total++;
        row.byType[e.type] = (row.byType[e.type] ?? 0) + 1;
      }
    }
    return [...map.values()].sort((a, b) => b.total - a.total || a.theme.localeCompare(b.theme));
  }, [entries]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    return rows.filter(r => {
      if (r.total < minCount) return false;
      if (q && !r.theme.toLowerCase().includes(q)) return false;
      return true;
    });
  }, [rows, query, minCount]);

  return (
    <div class="flex-1 flex flex-col min-h-0">
      <header class="bg-white/95 backdrop-blur border-b border-stone-200 sticky top-0 z-10">
        <div class="px-6 py-3 flex items-center gap-4 flex-wrap">
          <div class="flex items-baseline gap-2 min-w-0">
            <div class="text-[18px] font-semibold tracking-tight text-stone-900">主题</div>
            <div class="text-[11px] text-stone-400 tabular-nums">
              {filtered.length}{filtered.length !== rows.length && <span> / {rows.length}</span>}
            </div>
          </div>
          <input
            type="search"
            placeholder="过滤主题名…"
            value={rawQuery}
            onInput={e => setRawQuery((e.target as HTMLInputElement).value)}
            class="flex-1 min-w-[200px] max-w-[420px] px-3 py-1.5 border border-stone-300 rounded text-[13px] focus:outline-none focus:border-stone-500 bg-white"
          />
          <div class="flex items-center gap-1 text-[11px] text-stone-600">
            <span>出现 ≥</span>
            {[1, 2, 3, 5, 10].map(n => (
              <button
                key={n}
                onClick={() => setMinCount(n)}
                class={`px-1.5 py-0.5 rounded tabular-nums ${minCount === n ? 'bg-stone-900 text-white' : 'hover:bg-stone-100'}`}
              >{n}</button>
            ))}
          </div>
        </div>
      </header>

      <main class="flex-1 overflow-auto scrollbar-thin px-6 py-4">
        {filtered.length === 0
          ? <div class="text-sm text-stone-500 py-20 text-center">没有匹配的主题</div>
          : (
            <>
              <div class="flex flex-wrap gap-1.5">
                {filtered.slice(0, limit).map(r => {
                  // Precompute the sorted byType list so we only walk it once.
                  const sortedByType = (Object.entries(r.byType) as [EntryType, number][])
                    .sort((a, b) => b[1] - a[1]);
                  const topType = sortedByType[0]?.[0];
                  return (
                    <button
                      key={r.theme}
                      onClick={() => onThemeClick(r.theme, topType)}
                      class="group inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full border border-stone-200 bg-white hover:border-amber-300 hover:bg-amber-50 transition text-[12px]"
                      style={{ contentVisibility: 'auto', containIntrinsicSize: '28px 120px' }}
                      title={
                        `${r.theme} · 共 ${r.total} 条\n` +
                        sortedByType.map(([t, n]) => `  ${TYPE_LABEL[t] ?? t}: ${n}`).join('\n')
                      }
                    >
                      <span class="text-stone-800 group-hover:text-amber-900">{r.theme}</span>
                      <span class="text-stone-400 tabular-nums text-[11px]">{r.total}</span>
                      <span class="inline-flex gap-0.5 ml-0.5">
                        {sortedByType.slice(0, 3).map(([t]) => (
                          <span key={t} class={`w-1.5 h-1.5 rounded-full ${TYPE_DOT[t] ?? 'bg-stone-300'}`} />
                        ))}
                      </span>
                    </button>
                  );
                })}
              </div>
              {filtered.length > limit && (
                <div class="text-center mt-6">
                  <button
                    onClick={() => setLimit(l => l + LOAD_STEP)}
                    class="px-4 py-2 bg-white border border-stone-300 rounded text-[13px] hover:bg-stone-50"
                  >
                    再加载 {Math.min(LOAD_STEP, filtered.length - limit)} ( 已显示 {limit} / {filtered.length} )
                  </button>
                </div>
              )}
            </>
          )
        }
      </main>
    </div>
  );
}
