import { useState, useEffect, useCallback, useRef, useMemo } from 'preact/hooks';
import type { JSX } from 'preact';
import { marked } from 'marked';
import type { Entry } from '../types';
import { TYPE_BY_ID } from '../types';
import { resolveWikilinks, bookSlugOf } from '../wiki';
import { fetchEntryText, putEntryText, replaceBody } from '../api';
import { PropertyPanel } from './PropertyPanel';
import { NoteEditor } from './NoteEditor';

interface Props {
  entry: Entry | null;
  entries: Entry[];
  authorIndex: Map<string, Entry[]>;
  annotationIndex: Map<string, Entry[]>;
  wikiIndex: Map<string, Entry>;
  editable: boolean;
  onClose: () => void;
  onNavigate: (entry: Entry) => void;
  onThemeClick: (theme: string, fromType?: Entry['type']) => void;
  onUpdated: (updated: Entry) => void;
  onCreateAnnotation: (target: Entry) => Promise<void>;
  onDelete: (entry: Entry) => Promise<void>;
}

type SaveStatus = 'idle' | 'dirty' | 'saving' | 'saved' | 'error';

const SAVE_DEBOUNCE_MS = 1500;

export function Reader({
  entry, entries, authorIndex, annotationIndex, wikiIndex, editable,
  onClose, onNavigate, onThemeClick, onUpdated, onCreateAnnotation, onDelete,
}: Props) {
  // raw text and rendered preview are tracked separately — preview only used
  // in read-only mode, raw text reused as the frontmatter base when saving.
  const [rawText, setRawText] = useState('');
  const [rendered, setRendered] = useState('');
  const [body, setBody] = useState('');
  const [loading, setLoading] = useState(false);
  const [saveStatus, setSaveStatus] = useState<SaveStatus>('idle');
  const [saveErr, setSaveErr] = useState<string | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);

  // Refs hold the latest rawText/body so the debounced flusher reads fresh
  // values without re-arming on every keystroke.
  const rawRef = useRef('');
  const bodyRef = useRef('');
  const timerRef = useRef<number | null>(null);
  const statusRef = useRef<SaveStatus>('idle');
  rawRef.current = rawText;
  bodyRef.current = body;
  statusRef.current = saveStatus;

  const editablePath = entry?.path ?? null;

  // Flush any pending save synchronously (e.g. before switching entries or
  // closing the drawer). Returns the promise so callers can await it.
  const flushSave = useCallback(async () => {
    if (timerRef.current != null) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
    if (!editablePath) return;
    if (statusRef.current !== 'dirty') return;
    setSaveStatus('saving');
    try {
      const out = replaceBody(rawRef.current, bodyRef.current);
      await putEntryText(editablePath, out);
      rawRef.current = out;
      setRawText(out);
      setSaveStatus('saved');
      setSaveErr(null);
    } catch (e) {
      setSaveStatus('error');
      setSaveErr(e instanceof Error ? e.message : String(e));
    }
  }, [editablePath]);

  // Load entry body on mount / entry switch. If a prior edit was dirty, flush
  // it first so we don't lose in-flight changes when navigating.
  useEffect(() => {
    if (!entry) return;
    let cancelled = false;
    const path = entry.path;
    setLoading(true);
    setRendered('');
    setRawText('');
    setBody('');
    setSaveStatus('idle');
    setSaveErr(null);

    (async () => {
      try {
        const text = await fetchEntryText(path);
        if (cancelled) return;
        const bodyOnly = text.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n?/, '');
        rawRef.current = text;
        bodyRef.current = bodyOnly;
        setRawText(text);
        setBody(bodyOnly);
        if (!editable) {
          const resolved = resolveWikilinks(bodyOnly, wikiIndex);
          const html = marked.parse(resolved);
          if (typeof html === 'string') setRendered(html);
          else {
            const s = await Promise.resolve(html);
            if (!cancelled) setRendered(s);
          }
        }
      } catch {
        if (!cancelled) setRendered('<p class="text-red-600">加载失败</p>');
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => { cancelled = true; };
  }, [entry?.path, editable, wikiIndex]);

  // Pending-save flush when entry switches.
  const prevPathRef = useRef<string | null>(null);
  useEffect(() => {
    const prev = prevPathRef.current;
    if (prev && prev !== entry?.path) {
      // Fire-and-forget; we already wrote the new entry above.
      flushSave();
    }
    prevPathRef.current = entry?.path ?? null;
  }, [entry?.path, flushSave]);

  const handleEditorChange = useCallback((newBody: string) => {
    bodyRef.current = newBody;
    setBody(newBody);
    setSaveStatus('dirty');
    if (timerRef.current != null) clearTimeout(timerRef.current);
    timerRef.current = window.setTimeout(() => {
      timerRef.current = null;
      flushSave();
    }, SAVE_DEBOUNCE_MS);
  }, [flushSave]);

  const onArticleClick = useCallback((e: MouseEvent) => {
    const target = e.target as HTMLElement | null;
    const a = target?.closest?.('[data-wiki]') as HTMLElement | null;
    if (!a) return;
    e.preventDefault();
    const path = a.dataset.wiki;
    const next = entries.find(x => x.path === path);
    if (next) onNavigate(next);
  }, [entries, onNavigate]);

  // Esc closes, but only after flushing.
  useEffect(() => {
    if (!entry) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        flushSave().finally(() => onClose());
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [entry, onClose, flushSave]);

  // Beforeunload safety net: don't let a hot reload eat unsaved bytes.
  useEffect(() => {
    const onUnload = (e: BeforeUnloadEvent) => {
      if (statusRef.current === 'dirty') {
        e.preventDefault();
        e.returnValue = '';
      }
    };
    window.addEventListener('beforeunload', onUnload);
    return () => window.removeEventListener('beforeunload', onUnload);
  }, []);

  const chapters = useMemo(() => {
    if (!entry || entry.type !== 'book-overview') return null;
    const slug = bookSlugOf(entry);
    if (!slug) return null;
    return entries
      .filter(e => e.type === 'chapter-summary' && e.book === slug)
      .sort((a, b) => a.path.localeCompare(b.path));
  }, [entry, entries]);

  const handleDelete = useCallback(async () => {
    if (!entry) return;
    const fallback = entry.title || entry.path.split('/').pop()!.replace(/\.md$/, '');
    if (!window.confirm(`将「${fallback}」移到回收站？\n\n文件会被移动到 vault/notes/.trash/ 下，带时间戳，不会立刻消失，但 reader 中将看不到。`)) return;
    // Don't auto-save dirty content into a file we're about to trash.
    if (timerRef.current != null) { clearTimeout(timerRef.current); timerRef.current = null; }
    setMenuOpen(false);
    try {
      await onDelete(entry);
    } catch (e) {
      setSaveStatus('error');
      setSaveErr(e instanceof Error ? e.message : String(e));
    }
  }, [entry, onDelete]);

  if (!entry) return null;

  const tMeta = TYPE_BY_ID[entry.type] ?? { label: entry.type, accent: 'bg-stone-100 text-stone-700' };
  const canDelete = entry.type === 'note';

  return (
    <div class="fixed inset-0 bg-black/40 z-50 flex justify-end" onClick={() => flushSave().finally(() => onClose())}>
      <div class="w-full max-w-6xl bg-white h-full overflow-hidden shadow-2xl flex flex-col" onClick={e => e.stopPropagation()}>
        <div class="bg-white/95 backdrop-blur border-b border-stone-200 px-6 py-3 flex items-center gap-3 relative">
          <span class={`text-[11px] px-1.5 py-0.5 rounded border ${tMeta.accent}`}>{tMeta.label}</span>
          <div class="text-[13px] font-medium text-stone-800 flex-1 truncate">
            {entry.title || entry.path.split('/').pop()!.replace(/\.md$/, '')}
          </div>

          {editable && <SaveIndicator status={saveStatus} errMsg={saveErr} />}

          {entry.type === 'chapter-summary' && entry.book && (
            <button
              onClick={() => {
                const book = entries.find(e => e.type === 'book-overview' && bookSlugOf(e) === entry.book);
                if (book) onNavigate(book);
              }}
              class="text-[11px] text-stone-600 hover:text-stone-900 underline whitespace-nowrap"
            >↑ 回到本书</button>
          )}

          {canDelete && (
            <div class="relative">
              <button
                onClick={() => setMenuOpen(v => !v)}
                class="text-stone-500 hover:text-stone-900 px-2 text-base leading-none"
                title="更多"
              >⋯</button>
              {menuOpen && (
                <div class="absolute right-0 top-full mt-1 bg-white border border-stone-200 rounded shadow-lg py-1 min-w-[160px] z-10">
                  <button
                    onClick={handleDelete}
                    class="w-full text-left px-3 py-1.5 text-[12px] text-red-600 hover:bg-red-50"
                  >移到回收站…</button>
                </div>
              )}
            </div>
          )}

          <button
            onClick={() => flushSave().finally(() => onClose())}
            class="text-stone-500 hover:text-stone-900 text-lg leading-none px-2"
          >✕</button>
        </div>

        <div class="flex-1 overflow-hidden flex min-h-0">
          {chapters && chapters.length > 0 && (
            <aside class="w-56 shrink-0 border-r border-stone-200 bg-stone-50 overflow-auto scrollbar-thin">
              <div class="px-4 py-3 text-[11px] uppercase tracking-wider text-stone-500 font-semibold">
                章节 ({chapters.length})
              </div>
              <ul class="pb-4">
                {chapters.map(c => (
                  <li key={c.path}>
                    <button
                      onClick={() => onNavigate(c)}
                      class="w-full text-left px-4 py-1.5 text-[12px] text-stone-700 hover:bg-stone-100 hover:text-stone-900 leading-snug line-clamp-2"
                    >
                      {c.title || c.path.split('/').pop()!.replace(/\.md$/, '')}
                    </button>
                  </li>
                ))}
              </ul>
            </aside>
          )}
          <div class="flex-1 min-w-0 flex flex-col">
            {loading
              ? <div class="px-8 py-10 text-sm text-stone-500">加载中…</div>
              : editable
                ? <NoteEditor
                    docId={entry.path}
                    initial={body}
                    onChange={handleEditorChange}
                    onSaveShortcut={() => flushSave()}
                  />
                : <div class="flex-1 overflow-auto scrollbar-thin">
                    <article
                      onClick={onArticleClick as unknown as JSX.MouseEventHandler<HTMLElement>}
                      class="prose-body text-[14px] text-stone-800 px-8 py-6 max-w-3xl"
                      dangerouslySetInnerHTML={{ __html: rendered }}
                    />
                  </div>
            }
          </div>
          <aside class="w-80 shrink-0 border-l border-stone-200 bg-stone-50/60 overflow-auto scrollbar-thin">
            <PropertyPanel
              entry={entry}
              entries={entries}
              authorIndex={authorIndex}
              annotationIndex={annotationIndex}
              onOpen={onNavigate}
              onThemeClick={(th) => { onClose(); onThemeClick(th, entry.type); }}
              onUpdated={onUpdated}
              onCreateAnnotation={onCreateAnnotation}
            />
          </aside>
        </div>
      </div>
    </div>
  );
}

function SaveIndicator({ status, errMsg }: { status: SaveStatus; errMsg: string | null }) {
  switch (status) {
    case 'idle':   return null;
    case 'dirty':  return <span class="text-[11px] text-stone-400">未保存…</span>;
    case 'saving': return <span class="text-[11px] text-stone-500">保存中…</span>;
    case 'saved':  return <span class="text-[11px] text-emerald-600">已保存</span>;
    case 'error':  return <span class="text-[11px] text-red-600" title={errMsg ?? ''}>保存失败</span>;
  }
}
