import type { Entry, EntryType } from '../types';
import { TYPE_BY_ID } from '../types';
import { Card } from './Card';
import { Dashboard } from './Dashboard';
import { Icon } from './Icon';

interface Props {
  entries: Entry[];
  type: EntryType;
  typeEntries: Entry[];
  filtered: Entry[];
  query: string;
  minRating: number;
  themeFilter: string | null;
  limit: number;
  onOpenSearch: () => void;
  onClearQuery: () => void;
  onMinRatingChange: (n: number) => void;
  onClearTheme: () => void;
  onLoadMore: () => void;
  onCardClick: (entry: Entry, modifiers: { meta: boolean }) => void;
  onThemeClick: (theme: string) => void;
}

export function ListView({
  entries: _entries, type, typeEntries, filtered, query, minRating, themeFilter, limit,
  onOpenSearch, onClearQuery, onMinRatingChange, onClearTheme, onLoadMore, onCardClick, onThemeClick,
}: Props) {
  void _entries;
  const typeMeta = TYPE_BY_ID[type];
  const isFiltered = !!(query || themeFilter || minRating);
  const visible = query ? filtered : filtered.slice(0, limit);

  return (
    <div class="flex-1 flex flex-col min-h-0">
      <header class="bg-surface/95 backdrop-blur border-b border-base sticky top-0 z-10">
        <div class="px-6 py-3 flex items-center gap-4 flex-wrap">
          <div class="flex items-baseline gap-2 min-w-0">
            <div class="text-[18px] font-semibold tracking-tight text-primary truncate">
              {typeMeta?.label ?? type}
            </div>
            <div class="text-[11px] text-muted tabular-nums">
              {filtered.length}{filtered.length !== typeEntries.length && <span> / {typeEntries.length}</span>}
            </div>
          </div>

          {query ? (
            <div class="inline-flex items-center gap-1">
              <button
                onClick={onOpenSearch}
                title="点击修改 (⌘K)"
                class="inline-flex items-center gap-1 text-[12px] px-2 py-1 rounded bg-amber-100 text-amber-800 dark:bg-amber-950/40 dark:text-amber-300 border border-amber-200 dark:border-amber-800 hover:bg-amber-200 dark:hover:bg-amber-900/40 transition"
              >
                <Icon name="magnifying-glass" size={12} />
                <span class="truncate max-w-[200px]">{query}</span>
              </button>
              <button
                onClick={onClearQuery}
                title="清空"
                class="text-muted hover:text-primary p-1 rounded hover:bg-hover/60"
              >
                <Icon name="x" size={12} />
              </button>
            </div>
          ) : (
            <button
              onClick={onOpenSearch}
              title="搜索 (⌘K)"
              aria-label="搜索"
              class="text-muted hover:text-primary p-1.5 rounded hover:bg-hover/60"
            >
              <Icon name="magnifying-glass" size={16} />
            </button>
          )}

          <div class="flex items-center gap-1 text-[11px] text-secondary">
            <span>评分 ≥</span>
            {[0, 1, 2, 3, 4].map(n => (
              <button
                key={n}
                onClick={() => onMinRatingChange(n)}
                class={`px-1.5 py-0.5 rounded ${minRating === n ? 'bg-inverse text-inverse-fg' : 'hover:bg-surface-2'}`}
              >{n || '·'}</button>
            ))}
          </div>
        </div>
        {themeFilter && (
          <div class="px-6 pb-2 flex items-center gap-2">
            <span class="text-[11px] text-muted">主题筛选</span>
            <button
              onClick={onClearTheme}
              class="text-[11px] px-2 py-0.5 rounded bg-amber-100 text-amber-800 dark:bg-amber-950/40 dark:text-amber-300 border border-amber-200 hover:bg-amber-200  transition"
            >
              {themeFilter} <span class="text-amber-600 dark:text-amber-400 ml-1">✕</span>
            </button>
          </div>
        )}
      </header>

      <main class="flex-1 overflow-auto scrollbar-thin px-6 py-4">
        {!isFiltered && (
          <Dashboard
            type={type}
            typeEntries={typeEntries}
            onThemeClick={onThemeClick}
            onOpen={e => onCardClick(e, { meta: false })}
          />
        )}
        {filtered.length === 0
          ? <div class="text-sm text-muted py-20 text-center">没有匹配的条目</div>
          : (
            <>
              <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3">
                {visible.map(e => (
                  <Card
                    entry={e}
                    onClick={(entry, ev) => onCardClick(entry, { meta: ev.metaKey || ev.ctrlKey })}
                    key={e.path}
                  />
                ))}
              </div>
              {!query && !themeFilter && filtered.length > limit && (
                <div class="text-center mt-6">
                  <button
                    onClick={onLoadMore}
                    class="px-4 py-2 bg-surface border border-strong rounded text-sm hover:bg-page"
                  >
                    再加载 500 ( 已显示 {limit} / {filtered.length} )
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

