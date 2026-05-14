import { useState, useEffect, useMemo, useRef } from 'preact/hooks';
import type { Entry } from '../types';
import { TYPE_BY_ID } from '../types';
import { TypeIcon } from './TypeIcon';

interface Props {
  open: boolean;
  entries: Entry[];
  onClose: () => void;
  /** modifiers.meta = open in new tab */
  onPick: (entry: Entry, modifiers: { meta: boolean }) => void;
}

const MAX_RESULTS = 12;

/**
 * Rank entries by how well they match the query. Bias matches:
 *  - title hit > author hit > themes hit > preview hit
 *  - earlier substring position = higher score
 *  - higher rating_score = tiebreaker boost
 */
function score(entry: Entry, q: string): number {
  const t = (entry.title ?? '').toLowerCase();
  const a = (entry.author ?? '').toLowerCase();
  const th = (entry.themes ?? []).join(' ').toLowerCase();
  const pv = (entry.preview ?? '').toLowerCase();

  let s = 0;
  let idx;
  if ((idx = t.indexOf(q)) >= 0) s += 1000 - idx;
  if ((idx = a.indexOf(q)) >= 0) s += 500  - idx;
  if ((idx = th.indexOf(q)) >= 0) s += 300 - idx;
  if ((idx = pv.indexOf(q)) >= 0) s += 100 - idx;
  if (s > 0) s += (entry.rating_score || 0) * 10;
  return s;
}

export function CommandPalette({ open, entries, onClose, onPick }: Props) {
  const [query, setQuery] = useState('');
  const [active, setActive] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  // Reset whenever the palette opens.
  useEffect(() => {
    if (open) { setQuery(''); setActive(0); inputRef.current?.focus(); }
  }, [open]);

  const results = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return [];
    const scored: { e: Entry; s: number }[] = [];
    for (const e of entries) {
      const s = score(e, q);
      if (s > 0) scored.push({ e, s });
    }
    scored.sort((a, b) => b.s - a.s);
    return scored.slice(0, MAX_RESULTS).map(x => x.e);
  }, [entries, query]);

  // Clamp active index if results shrink.
  useEffect(() => { if (active >= results.length) setActive(0); }, [results.length, active]);

  if (!open) return null;

  const handleKey = (ev: KeyboardEvent) => {
    if (ev.key === 'Escape') { ev.preventDefault(); onClose(); return; }
    if (ev.key === 'ArrowDown') {
      ev.preventDefault();
      setActive(i => Math.min(results.length - 1, i + 1));
    } else if (ev.key === 'ArrowUp') {
      ev.preventDefault();
      setActive(i => Math.max(0, i - 1));
    } else if (ev.key === 'Enter') {
      ev.preventDefault();
      const target = results[active];
      if (target) {
        onPick(target, { meta: ev.metaKey || ev.ctrlKey });
        onClose();
      }
    }
  };

  return (
    <div class="fixed inset-0 bg-black/30 z-50 flex items-start justify-center pt-[15vh] px-4" onClick={onClose}>
      <div
        class="w-full max-w-[640px] bg-white border border-stone-200 rounded-lg shadow-2xl overflow-hidden"
        onClick={e => e.stopPropagation()}
      >
        <input
          ref={inputRef}
          type="search"
          placeholder="搜索 标题 / 作者 / 主题 / 正文…  (Enter 打开 · Cmd+Enter 新 tab · Esc 关闭)"
          value={query}
          onInput={e => setQuery((e.target as HTMLInputElement).value)}
          onKeyDown={handleKey}
          class="w-full px-4 py-3 text-[14px] focus:outline-none border-b border-stone-200"
        />
        <div class="max-h-[60vh] overflow-auto scrollbar-thin">
          {query.trim() === '' ? (
            <div class="px-4 py-6 text-sm text-stone-400 text-center">
              开始输入以搜索 vault 中 {entries.length} 个条目…
            </div>
          ) : results.length === 0 ? (
            <div class="px-4 py-6 text-sm text-stone-400 text-center">
              没有匹配的条目
            </div>
          ) : (
            <ul>
              {results.map((e, i) => {
                const meta = TYPE_BY_ID[e.type];
                const isActive = i === active;
                return (
                  <li key={e.path}>
                    <button
                      onClick={(ev) => {
                        onPick(e, { meta: ev.metaKey || ev.ctrlKey });
                        onClose();
                      }}
                      onMouseEnter={() => setActive(i)}
                      class={`w-full flex items-center gap-2.5 px-3 py-2 text-left text-[13px] border-b border-stone-100 last:border-b-0 ${
                        isActive ? 'bg-amber-50' : 'hover:bg-stone-50'
                      }`}
                    >
                      <TypeIcon type={e.type} scale={1.4} />
                      <div class="flex-1 min-w-0">
                        <div class="truncate text-stone-900">{e.title || e.path.split('/').pop()!.replace(/\.md$/, '')}</div>
                        <div class="truncate text-[11px] text-stone-500">
                          {meta?.label}
                          {e.author && <span> · {e.author}</span>}
                          {e.year && <span> · <span class="tabular-nums">{e.year}</span></span>}
                          {e.rating && <span class="ml-1 text-amber-600">{e.rating}</span>}
                        </div>
                      </div>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </div>
    </div>
  );
}
