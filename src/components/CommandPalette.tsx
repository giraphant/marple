import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import type { Entry, EntryType, TypeMeta } from '../types';
import type { SearchDocument } from '../search';
import { searchDocuments } from '../search';
import { searchIndex } from '../api';
import { TypeIcon } from './TypeIcon';
import { Icon } from './Icon';

interface Props {
  open: boolean;
  documents: SearchDocument<Entry>[];
  /** Type sections render in this order. Pass `orderedTypes(settings)`. */
  typeOrder: TypeMeta[];
  /** If set, that type's section is promoted to the top of the palette,
   *  with remaining sections still in `typeOrder`. App passes the active
   *  ListView's type when the palette is opened from a list's 🔍 button. */
  sourceType: EntryType | null;
  /** Initial query. The palette keeps keystrokes local and only commits
   *  through `onViewAll`, avoiding background ListView recomputation. */
  query: string;
  /** "lex" (快速) or "hybrid" (深度). Tab toggles in-palette. */
  searchMode: 'lex' | 'hybrid';
  onToggleSearchMode: () => void;
  onClose: () => void;
  /** Pick a single result. modifiers.meta → open in a new tab. */
  onPick: (entry: Entry, modifiers: { meta: boolean }) => void;
  /** "查看全部 N 条 →" — close palette, jump to that type's List, keep query. */
  onViewAll: (type: EntryType, query: string) => void;
}

const PER_TYPE_LIMIT = 5;

interface Section {
  meta: TypeMeta;
  total: number;
  top: Entry[];
}

export function CommandPalette({
  open, documents, typeOrder, sourceType, query, searchMode, onToggleSearchMode,
  onClose, onPick, onViewAll,
}: Props) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [draftQuery, setDraftQuery] = useState(query);
  const [serverSearch, setServerSearch] = useState<{
    query: string;
    entries: Entry[];
    loading: boolean;
    error: string | null;
  } | null>(null);

  // Focus + select-all on open so the user can either keep typing into the
  // existing query or start fresh by typing over it.
  useEffect(() => {
    if (open) {
      setDraftQuery(query);
      inputRef.current?.focus();
      inputRef.current?.select();
    }
  }, [open, query]);

  useEffect(() => {
    const q = draftQuery.trim();
    if (!open || !q) {
      setServerSearch(null);
      return;
    }

    const controller = new AbortController();
    setServerSearch(prev => (
      prev?.query === q
        ? { ...prev, loading: true, error: null }
        : { query: q, entries: [], loading: true, error: null }
    ));

    const timer = window.setTimeout(() => {
      searchIndex({ q, limit: 300, mode: searchMode, signal: controller.signal })
        .then(items => {
          setServerSearch({
            query: q,
            entries: items.map(item => item.entry),
            loading: false,
            error: null,
          });
        })
        .catch(err => {
          if (controller.signal.aborted) return;
          setServerSearch({
            query: q,
            entries: [],
            loading: false,
            error: err instanceof Error ? err.message : String(err),
          });
        });
    }, 160);

    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
  }, [open, draftQuery, searchMode]);

  // Effective section order: sourceType (if any) first, then the rest of
  // typeOrder. When the palette opens from Cmd+K or Sidebar 🔍, sourceType
  // is null and we get strict sidebar order. When opened from a ListView's
  // 🔍, the user's current type is promoted to the top so "where they came
  // from" is the section they see first.
  const effectiveOrder = useMemo<TypeMeta[]>(() => {
    if (!sourceType) return typeOrder;
    const source = typeOrder.find(t => t.id === sourceType);
    if (!source) return typeOrder;
    return [source, ...typeOrder.filter(t => t.id !== sourceType)];
  }, [typeOrder, sourceType]);

  // Score → bucket by type → sort within bucket → top-N. Sections render
  // in `effectiveOrder`; empty sections are dropped.
  const sections = useMemo<Section[]>(() => {
    if (!draftQuery.trim()) return [];
    const buckets = new Map<EntryType, { e: Entry; s: number }[]>();
    const readyServerEntries =
      serverSearch?.query === draftQuery.trim() && !serverSearch.loading && !serverSearch.error
        ? serverSearch.entries
        : null;
    if (readyServerEntries) {
      readyServerEntries.forEach((entry, index) => {
        let bucket = buckets.get(entry.type);
        if (!bucket) { bucket = []; buckets.set(entry.type, bucket); }
        bucket.push({ e: entry, s: readyServerEntries.length - index });
      });
    } else {
      for (const result of searchDocuments(documents, draftQuery)) {
        let bucket = buckets.get(result.entry.type);
        if (!bucket) { bucket = []; buckets.set(result.entry.type, bucket); }
        bucket.push({ e: result.entry, s: result.score });
      }
    }
    const out: Section[] = [];
    for (const meta of effectiveOrder) {
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
  }, [documents, draftQuery, effectiveOrder, serverSearch]);

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
    if (ev.key === 'Tab') {
      ev.preventDefault();
      onToggleSearchMode();
      return;
    }
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
        class="w-full max-w-[720px] bg-surface border border-base rounded-2xl shadow-soft-lg overflow-hidden"
        onClick={e => e.stopPropagation()}
      >
        <div class="flex items-center gap-2 px-3 border-b border-base">
          <Icon name="magnifying-glass" size={16} class="text-muted shrink-0" />
          <span
            class={`text-[11px] px-1.5 py-0.5 rounded shrink-0 cursor-pointer select-none ${
              searchMode === 'hybrid'
                ? 'bg-accent-bg text-accent-text'
                : 'bg-surface-2 text-secondary'
            }`}
            title="Tab 切换模式"
            onClick={onToggleSearchMode}
          >
            {searchMode === 'hybrid' ? '深度' : '快速'}
          </span>
          <input
            ref={inputRef}
            type="search"
            placeholder={searchMode === 'lex'
              ? '快速检索 标题/作者/主题/正文…  Tab 切深度 · ⏎ 打开 · Esc 关闭'
              : '深度检索 跨语言 / 概念 / 自然语言…  Tab 切回快速 · ⏎ 打开 · Esc 关闭'}
            value={draftQuery}
            onInput={e => setDraftQuery((e.target as HTMLInputElement).value)}
            class="flex-1 py-3 bg-transparent text-[14px] focus:outline-none"
          />
          {draftQuery && (
            <button
              onClick={() => { setDraftQuery(''); inputRef.current?.focus(); }}
              title="清空"
              class="text-muted hover:text-primary p-1 rounded hover:bg-hover/60"
            >
              <Icon name="x" size={14} />
            </button>
          )}
          {serverSearch?.query === draftQuery.trim() && serverSearch.loading && (
            <span class="text-[11px] text-muted shrink-0">
              {searchMode === 'hybrid' ? '深度…（首次加载语义模型 ~2s）' : '全文…'}
            </span>
          )}
          {serverSearch?.query === draftQuery.trim() && serverSearch.error && (
            <span class="text-[11px] text-danger shrink-0" title={serverSearch.error}>
              本地
            </span>
          )}
        </div>
        <div class="max-h-[80vh] overflow-auto scrollbar-thin">
          {draftQuery.trim() === '' ? (
            <div class="px-4 py-6 text-sm text-muted text-center">
              开始输入以搜索 vault 中 {documents.length} 个条目…
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
                            class="w-full flex items-center gap-2.5 px-3 py-2 text-left text-[13px] hover:bg-page focus:bg-accent-bg focus:outline-none"
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
                                {e.rating && <span class="ml-1 text-star">{e.rating}</span>}
                              </div>
                            </div>
                          </button>
                        </li>
                      ))}
                    </ul>
                    {sec.total > sec.top.length && (
                      <button
                        onClick={() => onViewAll(sec.meta.id, draftQuery)}
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
