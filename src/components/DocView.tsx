import { useState, useEffect, useCallback, useRef, useMemo } from 'preact/hooks';
import type { Entry } from '../types';
import { TYPE_BY_ID } from '../types';
import { bookSlugOf } from '../wiki';
import { fetchEntryText, putEntryText, replaceBody } from '../api';
import { PropertyPanel } from './PropertyPanel';
import { NoteEditor, type EditorThemeConfig } from './NoteEditor';
import { Icon } from './Icon';
import { BodyView } from '../body/BodyView';
import type { CitationFormat } from '../citation';

interface Props {
  entry: Entry;
  entries: Entry[];
  authorIndex: Map<string, Entry[]>;
  annotationIndex: Map<string, Entry[]>;
  wikiIndex: Map<string, Entry>;
  editable: boolean;
  editorTheme: EditorThemeConfig;
  citationFormat: CitationFormat;
  onNavigate: (entry: Entry, modifiers: { meta: boolean }) => void;
  onThemeClick: (theme: string, fromType?: Entry['type']) => void;
  onUpdated: (updated: Entry) => void;
  onCreateAnnotation: (target: Entry) => Promise<void>;
  onDelete: (entry: Entry) => Promise<void>;
}

type SaveStatus = 'idle' | 'dirty' | 'saving' | 'saved' | 'error';

const SAVE_DEBOUNCE_MS = 1500;

export function DocView({
  entry, entries, authorIndex, annotationIndex, wikiIndex, editable, editorTheme,
  citationFormat,
  onNavigate, onThemeClick, onUpdated, onCreateAnnotation, onDelete,
}: Props) {
  const [rawText, setRawText] = useState('');
  const [loadError, setLoadError] = useState(false);
  const [body, setBody] = useState('');
  const [loading, setLoading] = useState(false);
  const [saveStatus, setSaveStatus] = useState<SaveStatus>('idle');
  const [saveErr, setSaveErr] = useState<string | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);

  const rawRef = useRef('');
  const bodyRef = useRef('');
  const timerRef = useRef<number | null>(null);
  const statusRef = useRef<SaveStatus>('idle');
  rawRef.current = rawText;
  bodyRef.current = body;
  statusRef.current = saveStatus;

  const editablePath = entry.path;

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

  // Flush on entry switch (cleanup runs with the old flushSave closure
  // that targets the previous editablePath).
  useEffect(() => {
    return () => { flushSave(); };
  }, [flushSave]);

  useEffect(() => {
    let cancelled = false;
    const path = entry.path;
    setLoading(true);
    setLoadError(false);
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
      } catch {
        if (!cancelled) setLoadError(true);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => { cancelled = true; };
  }, [entry.path, editable, wikiIndex]);

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

  const onWikiClick = useCallback((path: string, modifiers: { meta: boolean }) => {
    const next = entries.find(x => x.path === path);
    if (next) onNavigate(next, modifiers);
  }, [entries, onNavigate]);

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

  // EPUB-style book context: when looking at a book-overview OR any of its
  // chapters, we want the same left rail visible. `overview` is the book's
  // top-level entry, `chapters` is the ordered chapter list. Returns null
  // when the current entry isn't part of a book.
  const bookContext = useMemo(() => {
    let slug: string | null = null;
    if (entry.type === 'book-overview') slug = bookSlugOf(entry);
    else if (entry.type === 'chapter-summary') slug = entry.book;
    if (!slug) return null;
    const overview = entries.find(e => e.type === 'book-overview' && bookSlugOf(e) === slug) ?? null;
    const chapters = entries
      .filter(e => e.type === 'chapter-summary' && e.book === slug)
      .sort((a, b) => a.path.localeCompare(b.path));
    if (!overview && chapters.length === 0) return null;
    return { slug, overview, chapters };
  }, [entry, entries]);

  const handleDelete = useCallback(async () => {
    const fallback = entry.title || entry.path.split('/').pop()!.replace(/\.md$/, '');
    if (!window.confirm(`将「${fallback}」移到回收站？\n\n文件会被移动到 vault/notes/.trash/ 下，带时间戳，不会立刻消失，但 reader 中将看不到。`)) return;
    if (timerRef.current != null) { clearTimeout(timerRef.current); timerRef.current = null; }
    setMenuOpen(false);
    try {
      await onDelete(entry);
    } catch (e) {
      setSaveStatus('error');
      setSaveErr(e instanceof Error ? e.message : String(e));
    }
  }, [entry, onDelete]);

  const tMeta = TYPE_BY_ID[entry.type] ?? { label: entry.type, accent: 'bg-surface-2 text-secondary' };
  const canDelete = entry.type === 'note';

  // Notes 的 frontmatter `title:` 在 build-index 后不会再随用户编辑更新；
  // 头部用 body 第一行 H 标题派生，编辑器输入会触发 setBody 进而重算，
  // 实现 live 跟随。tab 名 / 卡片 / sidebar 仍走 entry.title（下次 reindex 时正确）。
  const displayTitle = useMemo(() => {
    if (entry.type === 'note') {
      const m = body.match(/^#+\s+(.+?)\s*$/m);
      if (m) return m[1].trim();
    }
    return entry.title || entry.path.split('/').pop()!.replace(/\.md$/, '');
  }, [entry, body]);

  return (
    <div class="flex-1 flex flex-col min-h-0">
      <div class="bg-surface/95 backdrop-blur border-b border-base px-6 py-3 flex items-center gap-3 relative shrink-0">
        <span class={`text-[11px] px-1.5 py-0.5 rounded border ${tMeta.accent}`}>{tMeta.label}</span>
        <div class="text-[14px] font-medium text-primary flex-1 truncate">
          {displayTitle}
        </div>

        {editable && <SaveIndicator status={saveStatus} errMsg={saveErr} />}

        {canDelete && (
          <div class="relative">
            <button
              onClick={() => setMenuOpen(v => !v)}
              class="text-muted hover:text-primary p-1 inline-flex items-center"
              title="更多"
            ><Icon name="dots-three" size={16} /></button>
            {menuOpen && (
              <div class="absolute right-0 top-full mt-1 bg-surface border border-base rounded shadow-lg py-1 min-w-[160px] z-10">
                <button
                  onClick={handleDelete}
                  class="w-full text-left px-3 py-1.5 text-[12px] text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950/30"
                >移到回收站…</button>
              </div>
            )}
          </div>
        )}
      </div>

      <div class="flex-1 overflow-hidden flex min-h-0">
        {bookContext && (
          <aside class="w-56 shrink-0 border-r border-base bg-page overflow-auto scrollbar-thin">
            {bookContext.overview && (
              <div class="px-2 pt-3 pb-1">
                <div class="text-[10px] uppercase tracking-wider text-muted font-semibold px-2 mb-1">本书</div>
                <BookRailRow
                  entry={bookContext.overview}
                  label="概述"
                  active={entry.path === bookContext.overview.path}
                  onClick={(ev) => onNavigate(bookContext.overview!, { meta: ev.metaKey || ev.ctrlKey })}
                />
              </div>
            )}
            {bookContext.chapters.length > 0 && (
              <>
                <div class="px-4 pt-3 pb-1 text-[10px] uppercase tracking-wider text-muted font-semibold">
                  章节 ({bookContext.chapters.length})
                </div>
                <ul class="pb-4 px-2">
                  {bookContext.chapters.map(c => {
                    const label = c.title || c.path.split('/').pop()!.replace(/\.md$/, '');
                    const isActive = c.path === entry.path;
                    return (
                      <li key={c.path}>
                        <BookRailRow
                          entry={c}
                          label={label}
                          active={isActive}
                          onClick={(ev) => onNavigate(c, { meta: ev.metaKey || ev.ctrlKey })}
                        />
                      </li>
                    );
                  })}
                </ul>
              </>
            )}
          </aside>
        )}
        <div class="flex-1 min-w-0 flex flex-col">
          {loading
            ? <div class="px-8 py-10 text-sm text-muted">加载中…</div>
            : editable
              ? <NoteEditor
                  docId={entry.path}
                  initial={body}
                  theme={editorTheme}
                  onChange={handleEditorChange}
                  onSaveShortcut={() => flushSave()}
                />
              : <div class="flex-1 overflow-auto scrollbar-thin">
                  {loadError
                    ? <p class="px-8 py-6 text-red-600 dark:text-red-400">加载失败</p>
                    : <BodyView entry={entry} body={body} wikiIndex={wikiIndex} onWikiClick={onWikiClick} />
                  }
                </div>
          }
        </div>
        <aside class="w-72 shrink-0 border-l border-base bg-page/60 overflow-auto scrollbar-thin">
          <PropertyPanel
            entry={entry}
            entries={entries}
            authorIndex={authorIndex}
            annotationIndex={annotationIndex}
            citationFormat={citationFormat}
            onOpen={(e) => onNavigate(e, { meta: false })}
            onThemeClick={(th) => onThemeClick(th, entry.type)}
            onUpdated={onUpdated}
            onCreateAnnotation={onCreateAnnotation}
          />
        </aside>
      </div>
    </div>
  );
}

function SaveIndicator({ status, errMsg }: { status: SaveStatus; errMsg: string | null }) {
  switch (status) {
    case 'idle':   return null;
    case 'dirty':  return <span class="text-[11px] text-muted">未保存…</span>;
    case 'saving': return <span class="text-[11px] text-muted">保存中…</span>;
    case 'saved':  return <span class="text-[11px] text-emerald-600 dark:text-emerald-400">已保存</span>;
    case 'error':  return <span class="text-[11px] text-red-600 dark:text-red-400" title={errMsg ?? ''}>保存失败</span>;
  }
}

/** One row in the EPUB-style book rail (concise + active highlight). */
function BookRailRow({ entry, label, active, onClick }: {
  entry: Entry;
  label: string;
  active: boolean;
  onClick: (ev: MouseEvent) => void;
}) {
  void entry;
  return (
    <button
      onClick={onClick}
      title={label}
      class={`w-full text-left px-2 py-1.5 rounded text-[12px] leading-snug truncate transition ${
        active
          ? 'bg-inverse text-inverse-fg font-medium'
          : 'text-secondary hover:bg-surface-2 hover:text-primary'
      }`}
    >
      {label}
    </button>
  );
}
