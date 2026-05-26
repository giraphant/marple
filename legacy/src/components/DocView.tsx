import { useState, useEffect, useLayoutEffect, useCallback, useRef, useMemo } from 'preact/hooks';
import { EditorView } from '@codemirror/view';
import type { Entry } from '../types';
import { TYPE_BY_ID } from '../types';
import { bookSlugOf } from '../wiki';
import { fetchEntryText, putEntryText, replaceBody } from '../api';
import { createSaveQueue } from '../save-queue';
import { bumpVaultVersion } from '../sync';
import { PropertyPanel, ActionsRow } from './PropertyPanel';
import { NoteEditor, type EditorThemeConfig } from './NoteEditor';
import { RightPanel, type PanelHeading } from './RightPanel';
import { extractHeadings } from '../doc-outline';
import { computeDocStats } from '../doc-stats';
import { loadScroll, saveScroll } from '../scroll-store';
import { Icon } from './Icon';
import { BodyView } from '../body/BodyView';
import type { CitationFormat } from '../citation';

interface Props {
  entry: Entry;
  entries: Entry[];
  authorIndex: Map<string, Entry[]>;
  annotationIndex: Map<string, Entry[]>;
  wikiIndex: Map<string, Entry>;
  /** When true the in-app CodeMirror editor is mounted. False in external-editor
   * mode — the body renders read-only and editing happens via {@link onOpenInEditor}. */
  editable: boolean;
  /** QUA-72: this entry is editable but the user chose to edit externally, so the
   * header shows a 「在外部编辑器打开」 action instead of an inline editor. */
  canEditExternally?: boolean;
  editorTheme: EditorThemeConfig;
  citationFormat: CitationFormat;
  /** Whether this entry has a translated PDF (gates the 「打开译本」 action). */
  hasTranslation: boolean;
  onNavigate: (entry: Entry, modifiers: { meta: boolean }) => void;
  onThemeClick: (theme: string, fromType?: Entry['type']) => void;
  onUpdated: (updated: Entry) => void;
  onCreateAnnotation: (target: Entry) => Promise<void>;
  onOpenInEditor?: (entry: Entry) => void | Promise<void>;
  onDelete: (entry: Entry) => Promise<void>;
}

type SaveStatus = 'idle' | 'dirty' | 'saving' | 'saved' | 'error' | 'conflict';

const SAVE_DEBOUNCE_MS = 1500;

export function DocView({
  entry, entries, authorIndex, annotationIndex, wikiIndex, editable, canEditExternally, editorTheme,
  citationFormat, hasTranslation,
  onNavigate, onThemeClick, onUpdated, onCreateAnnotation, onOpenInEditor, onDelete,
}: Props) {
  const [loadError, setLoadError] = useState(false);
  const [body, setBody] = useState('');
  const [loading, setLoading] = useState(false);
  const [saveStatus, setSaveStatus] = useState<SaveStatus>('idle');
  const [saveErr, setSaveErr] = useState<string | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  // Bumping this re-runs the load effect (and remounts the editor via its key),
  // used to pull a fresh copy from disk after a cross-window conflict.
  const [reloadNonce, setReloadNonce] = useState(0);

  const bodyRef = useRef('');
  const timerRef = useRef<number | null>(null);
  const statusRef = useRef<SaveStatus>('idle');
  const currentPathRef = useRef(entry.path);
  // The body most recently handed to the save queue (or freshly loaded).
  // Dirtiness is CONTENT-based — comparing this to the live body — never derived
  // from the UI save status, which the queue may flip to "saved" while a newer
  // keystroke is still only in component state.
  const lastQueuedBodyRef = useRef('');
  // True only after the current doc's body has loaded from disk. Guards against
  // saving an empty body when a load failed or is still in progress.
  const loadedOkRef = useRef(false);
  // Which doc's body is currently in `body` state. During an entry switch there
  // is a transient render where `entry` is the new doc but `body` still holds
  // the old doc's text; scroll restore must not act until these agree.
  const bodyPathRef = useRef('');
  bodyRef.current = body;
  statusRef.current = saveStatus;
  currentPathRef.current = entry.path;

  const editablePath = entry.path;

  // Per-path serialized save queue (see save-queue.ts). Created once; its deps
  // are all stable. onStatus only touches UI state for the visible doc.
  const saveQueue = useMemo(() => createSaveQueue({
    fetchText: fetchEntryText,
    putText: putEntryText,
    replaceBody,
    onStatus: (path, status, err) => {
      if (path !== currentPathRef.current) return;
      setSaveStatus(status);
      if (status === 'error') setSaveErr(err ?? null);
      else if (status === 'saved') setSaveErr(null);
    },
    onSaved: () => bumpVaultVersion(),
  }), []);

  const flushSave = useCallback(() => {
    if (timerRef.current != null) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
    if (!editablePath) return;
    if (!loadedOkRef.current) return; // never save a doc that didn't load OK
    if (bodyRef.current === lastQueuedBodyRef.current) return; // nothing new to save
    lastQueuedBodyRef.current = bodyRef.current;
    saveQueue.request(editablePath, bodyRef.current);
  }, [editablePath, saveQueue]);

  const reloadFromDisk = useCallback(() => {
    // Discard any queued (conflicting) edits — the user chose the on-disk copy.
    saveQueue.drop(entry.path);
    setReloadNonce(n => n + 1);
  }, [entry.path, saveQueue]);

  // Flush on entry switch (cleanup runs with the old flushSave closure
  // that targets the previous editablePath).
  useEffect(() => {
    return () => { flushSave(); };
  }, [flushSave]);

  useEffect(() => {
    let cancelled = false;
    const path = entry.path;
    loadedOkRef.current = false;
    lastQueuedBodyRef.current = ''; // matches the cleared body, so a failed load saves nothing
    setLoading(true);
    setLoadError(false);
    setBody('');
    setSaveStatus('idle');
    setSaveErr(null);

    (async () => {
      try {
        const text = await fetchEntryText(path);
        if (cancelled) return;
        const bodyOnly = text.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n?/, '');
        saveQueue.seedBase(path, text);
        lastQueuedBodyRef.current = bodyOnly;
        loadedOkRef.current = true;
        bodyRef.current = bodyOnly;
        bodyPathRef.current = path;
        setBody(bodyOnly);
      } catch {
        if (!cancelled) setLoadError(true);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => { cancelled = true; };
    // NOT wikiIndex: it changes on every cross-window index refetch/focus, and
    // reloading here would wipe unsaved edits. Cross-window content refresh is
    // handled by the mtime effect below, gated on a non-dirty editor.
  }, [entry.path, editable, reloadNonce]);

  // The refreshed index carries each file's mtime. If the *same* open doc's
  // mtime advances (another window saved it / external edit), pull the new body
  // — unless we have local unsaved edits, in which case the save-conflict guard
  // handles it instead of clobbering.
  const mtimeRef = useRef<{ path: string; mtime: number | null | undefined }>(
    { path: entry.path, mtime: entry.mtime },
  );
  useEffect(() => {
    const prev = mtimeRef.current;
    mtimeRef.current = { path: entry.path, mtime: entry.mtime };
    if (prev.path === entry.path && entry.mtime !== prev.mtime) {
      // Only pull the new copy if we have nothing in progress: no un-queued
      // local edits AND no save in flight. Otherwise the conflict guard / queue
      // handle it without clobbering.
      const clean = bodyRef.current === lastQueuedBodyRef.current
        && (statusRef.current === 'idle' || statusRef.current === 'saved');
      if (clean) reloadFromDisk();
    }
  }, [entry.path, entry.mtime, reloadFromDisk]);

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
      const unsaved = bodyRef.current !== lastQueuedBodyRef.current
        || (statusRef.current !== 'idle' && statusRef.current !== 'saved');
      if (unsaved) {
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

  // --- right panel (QUA-57): outline + stats ---
  // The rendered article scroll container (read mode) and the live EditorView
  // (edit mode) — so the 目录 tab can scroll to a heading in either mode.
  const bodyScrollRef = useRef<HTMLDivElement>(null);
  const editorViewRef = useRef<EditorView | null>(null);

  // --- QUA-68: per-doc read-mode scroll memory ---
  // The scroll container is reused across docs (no per-doc remount), so without
  // explicit save/restore the previous doc's pixel offset bleeds onto the next
  // when switching tabs. Key by path: DocTabs dedupe by path, so per-path ==
  // per-tab, and revisiting a doc restores where you left off.
  const restoringScrollRef = useRef(false);
  const scrollSaveTimerRef = useRef<number | null>(null);

  const onBodyScroll = useCallback(() => {
    if (restoringScrollRef.current) return;          // ignore the programmatic restore
    if (scrollSaveTimerRef.current != null) return;  // throttle to one save per window
    const path = currentPathRef.current;             // attribute to the doc scrolled now
    scrollSaveTimerRef.current = window.setTimeout(() => {
      scrollSaveTimerRef.current = null;
      if (currentPathRef.current !== path) return;   // switched away; leave-save already persisted it
      const el = bodyScrollRef.current;
      if (el) saveScroll(path, el.scrollTop);
    }, 150);
  }, []);

  // Persist the leaving doc's offset before its body is swapped out. The cleanup
  // runs while the DOM still shows the old content (and on unmount), so it reads
  // the right scroll for the doc we're leaving.
  useEffect(() => {
    const path = entry.path;
    return () => {
      if (scrollSaveTimerRef.current != null) {
        clearTimeout(scrollSaveTimerRef.current);
        scrollSaveTimerRef.current = null;
      }
      const el = bodyScrollRef.current;
      if (el) saveScroll(path, el.scrollTop);
    };
  }, [entry.path]);

  // Restore this doc's offset once its body has rendered (read mode only).
  // BodyView renders synchronously from `body`, so by the time loading is false
  // the container has its final height and the saved offset applies cleanly.
  useLayoutEffect(() => {
    if (editable || loading || loadError) return;
    if (bodyPathRef.current !== entry.path) return; // body still belongs to the previous doc
    const el = bodyScrollRef.current;
    if (!el) return;
    restoringScrollRef.current = true;
    el.scrollTop = loadScroll(entry.path);
    const raf = requestAnimationFrame(() => {
      const el2 = bodyScrollRef.current;
      if (el2) el2.scrollTop = loadScroll(entry.path); // re-assert after any reflow
      restoringScrollRef.current = false;
    });
    return () => cancelAnimationFrame(raf);
  }, [entry.path, body, loading, loadError, editable]);

  const docStats = useMemo(() => computeDocStats(body), [body]);

  // Edit mode: outline from markdown source (keys carry the source line).
  const editHeadings = useMemo<PanelHeading[]>(
    () => (editable
      ? extractHeadings(body).map(h => ({ level: h.level, text: h.text, key: `L${h.line}` }))
      : []),
    [editable, body],
  );

  // Read mode: outline from the actually-rendered DOM (BodyView routes some
  // sections through typed renderers, so the DOM is the source of truth). Assign
  // ids to the heading elements so clicks can scroll to them.
  const [domHeadings, setDomHeadings] = useState<PanelHeading[]>([]);
  useEffect(() => {
    if (editable || loading || loadError) { setDomHeadings([]); return; }
    const raf = requestAnimationFrame(() => {
      const root = bodyScrollRef.current;
      if (!root) { setDomHeadings([]); return; }
      const els = Array.from(
        root.querySelectorAll('.prose-body h1, .prose-body h2, .prose-body h3, .prose-body h4'),
      ) as HTMLElement[];
      setDomHeadings(els.map((el, i) => {
        const key = `toc-h-${i}`;
        el.id = key;
        el.style.scrollMarginTop = '12px';
        return { level: Number(el.tagName[1]) || 1, text: (el.textContent || '').trim(), key };
      }));
    });
    return () => cancelAnimationFrame(raf);
  }, [editable, body, entry.path, loading, loadError]);

  const headings = editable ? editHeadings : domHeadings;

  // Read-mode scroll-spy: highlight the topmost heading scrolled into view.
  const [activeHeadingKey, setActiveHeadingKey] = useState<string | null>(null);
  useEffect(() => {
    if (editable || domHeadings.length === 0) { setActiveHeadingKey(null); return; }
    const root = bodyScrollRef.current;
    if (!root) return;
    const els = domHeadings
      .map(h => root.querySelector('#' + CSS.escape(h.key)))
      .filter(Boolean) as HTMLElement[];
    if (els.length === 0) return;
    const io = new IntersectionObserver((entries) => {
      const visible = entries.filter(e => e.isIntersecting).map(e => e.target as HTMLElement);
      if (visible.length === 0) return;
      visible.sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
      setActiveHeadingKey(visible[0].id);
    }, { root, rootMargin: '0px 0px -70% 0px', threshold: 0 });
    els.forEach(el => io.observe(el));
    return () => io.disconnect();
  }, [editable, domHeadings]);

  const onHeadingClick = useCallback((key: string) => {
    if (editable) {
      const view = editorViewRef.current;
      if (!view) return;
      const lineNo = Number(key.slice(1)); // 'L<line>'
      if (!Number.isFinite(lineNo) || lineNo < 1 || lineNo > view.state.doc.lines) return;
      const line = view.state.doc.line(lineNo);
      view.dispatch({ selection: { anchor: line.from }, effects: EditorView.scrollIntoView(line.from, { y: 'start' }) });
      view.focus();
    } else {
      const el = bodyScrollRef.current?.querySelector('#' + CSS.escape(key)) as HTMLElement | null;
      el?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  }, [editable]);

  const panelBookContext = bookContext
    ? { overview: bookContext.overview, chapters: bookContext.chapters }
    : null;

  return (
    <div class="flex-1 flex flex-col min-h-0">
      <div class="bg-surface/95 backdrop-blur border-b border-base px-8 py-3.5 flex items-center gap-3 relative z-30 shrink-0">
        <span class={`text-[11px] px-2 py-0.5 rounded-lg font-medium shrink-0 ${tMeta.accent}`}>{tMeta.label}</span>
        <div class="flex items-baseline gap-2.5 min-w-0 flex-1">
          <span class="text-[15px] font-semibold tracking-[-0.01em] text-primary truncate">{displayTitle}</span>
          {(entry.type === 'paper-analysis' || entry.type === 'book-overview' || entry.type === 'chapter-summary')
            && (entry.author || entry.year || entry.rating) && (
            <span class="hidden md:inline-flex shrink-0 items-baseline gap-2 text-[12px] text-muted">
              {entry.author && <span class="truncate max-w-[240px]">{entry.author}</span>}
              {entry.year && <span class="tabular-nums">· {entry.year}</span>}
              {entry.rating && <span class="text-star tracking-tight">{entry.rating}</span>}
            </span>
          )}
        </div>

        {(entry.type === 'paper-analysis' || entry.type === 'book-overview') && (
          <ActionsRow entry={entry} defaultFormat={citationFormat} hasTranslation={hasTranslation} />
        )}

        {canEditExternally && onOpenInEditor && (
          <ExternalOpenButton entry={entry} onOpen={onOpenInEditor} />
        )}

        {editable && (saveStatus === 'conflict' ? (
          <span class="text-[11px] text-accent-text inline-flex items-center gap-1.5" title="磁盘上的文件在你编辑期间被其他窗口或外部改动；为避免覆盖，自动保存已暂停">
            文件已被其他窗口修改
            <button onClick={reloadFromDisk} class="underline hover:text-primary">重载</button>
          </span>
        ) : (
          <SaveIndicator status={saveStatus} errMsg={saveErr} />
        ))}

        {canDelete && (
          <div class="relative">
            <button
              onClick={() => setMenuOpen(v => !v)}
              class="text-muted hover:text-primary p-1 inline-flex items-center"
              title="更多"
            ><Icon name="dots-three" size={16} /></button>
            {menuOpen && (
              <div class="absolute right-0 top-full mt-1 bg-surface border border-base rounded-xl shadow-soft-lg py-1 min-w-[160px] z-10">
                <button
                  onClick={handleDelete}
                  class="w-full text-left px-3 py-1.5 text-[12px] text-danger hover:bg-danger-bg"
                >移到回收站…</button>
              </div>
            )}
          </div>
        )}
      </div>

      <div class="flex-1 overflow-hidden flex min-h-0">
        <div class="flex-1 min-w-0 flex flex-col">
          {loading
            ? <div class="px-8 py-10 text-sm text-muted">加载中…</div>
            : loadError
              // Show the failure for editable docs too — never mount the editor
              // on a failed load, or edits would be accepted but never saved.
              ? <div class="flex-1 flex items-center justify-center text-sm">
                  <div class="text-center">
                    <div class="mb-2 text-danger">加载失败</div>
                    <button onClick={reloadFromDisk} class="text-secondary underline">重试</button>
                  </div>
                </div>
              : editable
                ? <NoteEditor
                    key={`${entry.path}:${reloadNonce}`}
                    docId={entry.path}
                    initial={body}
                    theme={editorTheme}
                    onChange={handleEditorChange}
                    onSaveShortcut={() => flushSave()}
                    onViewReady={(v) => { editorViewRef.current = v; }}
                  />
                : <div ref={bodyScrollRef} onScroll={onBodyScroll} class="flex-1 overflow-auto scrollbar-thin">
                    <BodyView entry={entry} body={body} wikiIndex={wikiIndex} onWikiClick={onWikiClick} />
                  </div>
          }
        </div>
        <RightPanel
          headings={headings}
          activeHeadingKey={activeHeadingKey}
          onHeadingClick={onHeadingClick}
          bookContext={panelBookContext}
          activeEntryPath={entry.path}
          onNavigate={onNavigate}
          stats={docStats}
          info={
            <PropertyPanel
              entry={entry}
              entries={entries}
              authorIndex={authorIndex}
              annotationIndex={annotationIndex}
              onOpen={(e) => onNavigate(e, { meta: false })}
              onThemeClick={(th) => onThemeClick(th, entry.type)}
              onUpdated={onUpdated}
              onCreateAnnotation={onCreateAnnotation}
            />
          }
        />
      </div>
    </div>
  );
}

/** Header action to hand the current file to the external editor. Launching is
 *  fire-and-forget on the server, so the "正在打开…" affordance is bounded — it
 *  always clears within {@link OPENING_RESET_MS} even if the request is slow or
 *  fails, so the button can never appear stuck. Errors show inline (not a
 *  blocking modal, which would freeze the button until dismissed). */
const OPENING_RESET_MS = 1500;
function ExternalOpenButton({ entry, onOpen }: { entry: Entry; onOpen: (entry: Entry) => void | Promise<void> }) {
  const [opening, setOpening] = useState(false);
  const [failed, setFailed] = useState(false);
  const click = async () => {
    if (opening) return;
    setFailed(false);
    setOpening(true);
    let settled = false;
    const clear = () => { if (!settled) { settled = true; setOpening(false); } };
    const guard = setTimeout(clear, OPENING_RESET_MS);
    try {
      await onOpen(entry);
    } catch {
      setFailed(true);
      setTimeout(() => setFailed(false), 2500);
    } finally {
      clearTimeout(guard);
      clear();
    }
  };
  return (
    <button
      onClick={click}
      disabled={opening}
      class="shrink-0 inline-flex items-center gap-1.5 text-[11px] px-2.5 py-1 rounded-lg border border-base bg-surface hover:border-strong text-secondary hover:text-primary transition disabled:opacity-60"
      title="用外部编辑器打开这个文件（在设置里选择编辑器）"
    >
      <Icon name="pencil" size={13} />
      {opening ? '正在打开…' : failed ? '打开失败，重试' : '在外部编辑器打开'}
    </button>
  );
}

function SaveIndicator({ status, errMsg }: { status: SaveStatus; errMsg: string | null }) {
  switch (status) {
    case 'idle':   return null;
    case 'dirty':  return <span class="text-[11px] text-muted">未保存…</span>;
    case 'saving': return <span class="text-[11px] text-muted">保存中…</span>;
    case 'saved':  return <span class="text-[11px] text-success">已保存</span>;
    case 'error':  return <span class="text-[11px] text-danger" title={errMsg ?? ''}>保存失败</span>;
    case 'conflict': return null; // rendered inline in the header with a reload action
  }
}

