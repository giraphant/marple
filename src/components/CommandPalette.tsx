import { useEffect, useMemo, useRef } from 'preact/hooks';
import type { Entry, EntryType, TypeMeta } from '../types';
import { TypeIcon } from './TypeIcon';
import { Icon } from './Icon';

interface Props {
  open: boolean;
  entries: Entry[];
  /** Type sections render in this order. Pass `orderedTypes(settings)`. */
  typeOrder: TypeMeta[];
  /** Controlled. Same string the ListView uses, so closing the palette
   *  leaves a pre-filtered list behind (intentional — see design doc). */
  query: string;
  onQueryChange: (q: string) => void;
  onClose: () => void;
  /** Pick a single result. modifiers.meta → open in a new tab. */
  onPick: (entry: Entry, modifiers: { meta: boolean }) => void;
  /** "查看全部 N 条 →" — close palette, jump to that type's List, keep query. */
  onViewAll: (type: EntryType, query: string) => void;
}

const PER_TYPE_LIMIT = 5;

/** Rank entries by how well they match the query. Bias matches:
 *  - title hit > author hit > themes hit > topic hit > source hit > preview hit
 *  - earlier substring position = higher score
 *  - higher rating_score = tiebreaker boost */
function score(entry: Entry, q: string): number {
  const t  = (entry.title  ?? '').toLowerCase();
  const a  = (entry.author ?? '').toLowerCase();
  const th = (entry.themes ?? []).join(' ').toLowerCase();
  const tp = (entry.topic  ?? '').toLowerCase();
  const sr = (entry.source ?? '').toLowerCase();
  const pv = (entry.preview ?? '').toLowerCase();

  let s = 0;
  let idx;
  if ((idx = t.indexOf(q))  >= 0) s += 1000 - idx;
  if ((idx = a.indexOf(q))  >= 0) s += 500  - idx;
  if ((idx = th.indexOf(q)) >= 0) s += 300  - idx;
  if ((idx = tp.indexOf(q)) >= 0) s += 250  - idx;
  if ((idx = sr.indexOf(q)) >= 0) s += 200  - idx;
  if ((idx = pv.indexOf(q)) >= 0) s += 100  - idx;
  if (s > 0) s += (entry.rating_score || 0) * 10;
  return s;
}

interface Section {
  meta: TypeMeta;
  total: number;
  top: Entry[];
}

export function CommandPalette({
  open, entries, typeOrder, query, onQueryChange, onClose, onPick, onViewAll,
}: Props) {
  const inputRef = useRef<HTMLInputElement>(null);

  // Focus + select-all on open so the user can either keep typing into the
  // existing query or start fresh by typing over it.
  useEffect(() => {
    if (open) {
      inputRef.current?.focus();
      inputRef.current?.select();
    }
  }, [open]);

  // Score → bucket by type → sort within bucket → top-N. Sections render
  // in `typeOrder` (sidebar order); empty sections are dropped.
  const sections = useMemo<Section[]>(() => {
    const q = query.trim().toLowerCase();
    if (!q) return [];
    const buckets = new Map<EntryType, { e: Entry; s: number }[]>();
    for (const e of entries) {
      const s = score(e, q);
      if (s <= 0) continue;
      let bucket = buckets.get(e.type);
      if (!bucket) { bucket = []; buckets.set(e.type, bucket); }
      bucket.push({ e, s });
    }
    const out: Section[] = [];
    for (const meta of typeOrder) {
      const bucket = buckets.get(meta.id);
      if (!bucket || bucket.length === 0) continue;
      bucket.sort((a, b) => b.s - a.s);
      out.push({
        meta,
        total: bucket.length,
        top: bucket.slice(0, PER_TYPE_LIMIT).map(x => x.e),
      });
    }
    return out;
  }, [entries, query, typeOrder]);

  // Flat ordered list of all visible result rows, used for ↑/↓ navigation
  // across section boundaries. Section headers and "view all" links are
  // skipped by this index.
  const flatResults = useMemo(() => sections.flatMap(s => s.top), [sections]);

  if (!open) return null;

  const onPickRow = (e: Entry, ev: { metaKey: boolean; ctrlKey: boolean }) => {
    onPick(e, { meta: ev.metaKey || ev.ctrlKey });
    onClose();
  };

  const handleKey = (ev: KeyboardEvent) => {
    if (ev.key === 'Escape') { ev.preventDefault(); onClose(); return; }
    if (flatResults.length === 0) return;
    const target = ev.target as HTMLElement | null;
    // Find currently focused row index (by data-row-index attr on result buttons).
    const cur = target?.closest('[data-row-index]') as HTMLElement | null;
    const curIdx = cur ? parseInt(cur.getAttribute('data-row-index')!, 10) : -1;
    if (ev.key === 'ArrowDown') {
      ev.preventDefault();
      focusRow(curIdx < 0 ? 0 : Math.min(flatResults.length - 1, curIdx + 1));
    } else if (ev.key === 'ArrowUp') {
      ev.preventDefault();
      if (curIdx <= 0) { inputRef.current?.focus(); return; }
      focusRow(curIdx - 1);
    } else if (ev.key === 'Enter') {
      if (curIdx >= 0) { ev.preventDefault(); onPickRow(flatResults[curIdx], ev); return; }
      // Enter in the input with no row focused: pick the first result.
      if (flatResults[0]) { ev.preventDefault(); onPickRow(flatResults[0], ev); }
    }
  };

  return (
    <div
      class="fixed inset-0 bg-black/30 z-50 flex items-start justify-center pt-[3vh] px-4"
      onClick={onClose}
      onKeyDown={handleKey}
    >
      <div
        class="w-full max-w-[720px] bg-surface border border-base rounded-lg shadow-2xl overflow-hidden"
        onClick={e => e.stopPropagation()}
      >
        <div class="flex items-center gap-2 px-3 border-b border-base">
          <Icon name="magnifying-glass" size={16} class="text-muted shrink-0" />
          <input
            ref={inputRef}
            type="search"
            placeholder="搜索 标题 / 作者 / 主题 / 正文…  ⏎ 打开 · ⌘⏎ 新 tab · Esc 关闭"
            value={query}
            onInput={e => onQueryChange((e.target as HTMLInputElement).value)}
            class="flex-1 py-3 bg-transparent text-[14px] focus:outline-none"
          />
          {query && (
            <button
              onClick={() => { onQueryChange(''); inputRef.current?.focus(); }}
              title="清空"
              class="text-muted hover:text-primary p-1 rounded hover:bg-hover/60"
            >
              <Icon name="x" size={14} />
            </button>
          )}
        </div>
        <div class="max-h-[80vh] overflow-auto scrollbar-thin">
          {query.trim() === '' ? (
            <div class="px-4 py-6 text-sm text-muted text-center">
              开始输入以搜索 vault 中 {entries.length} 个条目…
            </div>
          ) : sections.length === 0 ? (
            <div class="px-4 py-6 text-sm text-muted text-center">
              没有匹配的条目
            </div>
          ) : (
            <div>
              {sections.map((sec, secIdx) => {
                // Compute the flat row index of this section's first row by
                // summing prior sections' top.length.
                const baseIdx = sections.slice(0, secIdx).reduce((n, s) => n + s.top.length, 0);
                return (
                  <section key={sec.meta.id} class="border-b border-base last:border-b-0">
                    <div class="flex items-center gap-2 px-3 py-1.5 bg-surface-2/50">
                      <TypeIcon type={sec.meta.id} scale={1.2} />
                      <span class="text-[12px] font-semibold text-primary">{sec.meta.label}</span>
                      <span class="text-[11px] text-muted tabular-nums">({sec.total})</span>
                    </div>
                    <ul>
                      {sec.top.map((e, i) => (
                        <li key={e.path}>
                          <button
                            data-row-index={baseIdx + i}
                            onClick={ev => onPickRow(e, ev)}
                            onMouseEnter={ev => (ev.currentTarget as HTMLElement).focus()}
                            class="w-full flex items-center gap-2.5 px-3 py-2 text-left text-[13px] hover:bg-page focus:bg-amber-50 dark:focus:bg-amber-950/30 focus:outline-none"
                          >
                            <TypeIcon type={e.type} scale={1.2} />
                            <div class="flex-1 min-w-0">
                              <div class="truncate text-primary">
                                {e.title || e.path.split('/').pop()!.replace(/\.md$/, '')}
                              </div>
                              <div class="truncate text-[11px] text-muted">
                                {sec.meta.label}
                                {e.author && <span> · {e.author}</span>}
                                {e.year && <span> · <span class="tabular-nums">{e.year}</span></span>}
                                {e.rating && <span class="ml-1 text-amber-600 dark:text-amber-400">{e.rating}</span>}
                              </div>
                            </div>
                          </button>
                        </li>
                      ))}
                    </ul>
                    {sec.total > sec.top.length && (
                      <button
                        onClick={() => { onViewAll(sec.meta.id, query); onClose(); }}
                        class="w-full text-left px-3 py-1.5 text-[12px] text-muted hover:text-primary hover:bg-page"
                      >
                        在「{sec.meta.label}」中查看全部 {sec.total} 条 →
                      </button>
                    )}
                  </section>
                );
              })}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function focusRow(idx: number) {
  const el = document.querySelector(`[data-row-index="${idx}"]`) as HTMLElement | null;
  el?.focus();
}
