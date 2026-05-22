import { useState, useEffect, useMemo, useCallback, useRef } from 'preact/hooks';
import type { Entry, EntryType, Tab, TabContent } from './types';
import { activeContent } from './types';
import { buildWikiIndex, splitAuthors } from './wiki';
import { buildSearchIndex, searchDocuments } from './search';
import { sortEntriesMulti, coerceSortClauses, type SortClause } from './list-sort';
import { applyFilters, makeClause, type FilterClause, type FilterMatch } from './list-filter';
import { ListView } from './components/ListView';
import { DocView } from './components/DocView';
import { TrashView } from './components/TrashView';
import { ThemesView } from './components/ThemesView';
import { ActivityView } from './components/ActivityView';
import { SettingsPanel } from './components/SettingsPanel';
import { CommandPalette } from './components/CommandPalette';
import { Sidebar } from './components/Sidebar';
import { TabBar } from './components/TabBar';
import {
  postEntryText, newAnnotationDraft, entryFromDraft, deleteEntry,
  newIdeaDraft, ideaEntryFromDraft, reindex, reconcile, fetchIndex, searchIndex as searchServerIndex,
  listFiles, fetchEntry, fetchTranslationSlugs, openInEditor,
} from './api';
import { nextSearchMode, type SearchMode } from './searchMode';
import { loadSettings, saveSettings, orderedTypes, fontStack, type Settings } from './settings';
import { loadTabs, loadActiveIndex, saveTabs, saveActiveIndex, defaultTab } from './session';
import { bumpVaultVersion, subscribeVaultChanges } from './sync';
import { mapPool } from './map-pool';

const MAX_TABS = 16;
const MAX_HISTORY = 50;
const DEFAULT_TYPE: EntryType = 'paper-analysis';

/** Max concurrent /api/entry fetches during a vault sync. Browsers cap a host at
 *  ~6 HTTP/1.1 connections; firing hundreds at once both fails with
 *  ERR_INSUFFICIENT_RESOURCES and starves user-initiated requests (a click on
 *  "open in editor" would queue behind the backlog). Kept well below 6 so that
 *  even with the (multi-second) /api/index load also in flight, connections stay
 *  free for user clicks. */
const SYNC_FETCH_CONCURRENCY = 3;

/** Push a new content to a tab's history at `cursor + 1`, truncating any
 *  forward history (browser-style). No-op if it's the same as current. */
function pushContent(tab: Tab, content: TabContent): Tab {
  const cur = tab.history[tab.cursor];
  if (cur && contentEq(cur, content)) return tab;
  const truncated = tab.history.slice(0, tab.cursor + 1);
  truncated.push(content);
  // Cap history length by dropping oldest entries; cursor stays at the end.
  while (truncated.length > MAX_HISTORY) truncated.shift();
  return { ...tab, history: truncated, cursor: truncated.length - 1 };
}

function contentEq(a: TabContent, b: TabContent): boolean {
  if (a.kind !== b.kind) return false;
  if (a.kind === 'list' && b.kind === 'list') return a.type === b.type;
  if (a.kind === 'doc' && b.kind === 'doc') return a.path === b.path;
  return false;
}

export function App() {
  const [entries, setEntries] = useState<Entry[] | null>(null);
  // Slugs that have a translated PDF (processing/translations/<slug>-zh.pdf).
  // Fetched live on boot; gates the 「打开译本」 button.
  const [translationSlugs, setTranslationSlugs] = useState<Set<string>>(() => new Set());
  const [query, setQuery] = useState('');
  // Flat multi-filter (QUA-63): a list of {field, op, value} clauses combined
  // by `filterMatch` (AND/OR). Ephemeral per browsing session; cleared on an
  // explicit sidebar type pick. Theme/author card clicks append clauses here.
  const [filters, setFilters] = useState<FilterClause[]>([]);
  const [filterMatch, setFilterMatch] = useState<FilterMatch>('all');
  const [limit, setLimit] = useState(300);
  const [settings, setSettings] = useState<Settings>(() => loadSettings());
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [tabs, setTabs] = useState<Tab[]>(() => loadTabs());
  const [activeIndex, setActiveIndex] = useState<number>(() => loadActiveIndex(loadTabs().length));
  const [paletteOpen, setPaletteOpen] = useState(false);
  // When the palette is triggered from a specific type's ListView (the
  // ListView header 🔍 button), that type's section gets promoted to the top
  // of the palette so the user sees "where they came from" first. Cmd+K /
  // Sidebar 🔍 leave this null → strict sidebar order.
  const [paletteSourceType, setPaletteSourceType] = useState<EntryType | null>(null);
  const [reindexing, setReindexing] = useState(false);
  const [searchMode, setSearchMode] = useState<SearchMode>('balanced');
  const toggleSearchMode = useCallback(() => {
    setSearchMode(prev => nextSearchMode(prev));
  }, []);
  const [listSearch, setListSearch] = useState<{
    key: string;
    entries: Entry[];
    loading: boolean;
    error: string | null;
  } | null>(null);

  const onReindex = useCallback(async () => {
    if (reindexing) return;
    setReindexing(true);
    try {
      const { skipped } = await reindex();
      setEntries(await fetchIndex());
      bumpVaultVersion();
      if (skipped.length > 0) {
        const lines = skipped.slice(0, 20).map(s => `· [${s.reason}] ${s.path}`).join('\n');
        const more = skipped.length > 20 ? `\n…还有 ${skipped.length - 20} 个` : '';
        window.alert(`重建完成，但有 ${skipped.length} 个文件 frontmatter 无法识别，未进入搜索索引：\n${lines}${more}`);
      }
    } catch (e) {
      window.alert('重建索引失败：' + (e instanceof Error ? e.message : String(e)));
    } finally {
      setReindexing(false);
    }
  }, [reindexing]);

  // Apply the theme by toggling `.dark` on <html>. For 'system', listen to
  // the OS preference and switch live when it changes. `resolvedDark` is the
  // current effective mode so the editor (CodeMirror) can pick up the same
  // theme via props.
  const [resolvedDark, setResolvedDark] = useState(false);
  useEffect(() => {
    const root = document.documentElement;
    const apply = (resolved: 'light' | 'dark') => {
      root.classList.toggle('dark', resolved === 'dark');
      setResolvedDark(resolved === 'dark');
    };
    if (settings.theme === 'system') {
      const mq = window.matchMedia('(prefers-color-scheme: dark)');
      apply(mq.matches ? 'dark' : 'light');
      const onChange = (e: MediaQueryListEvent) => apply(e.matches ? 'dark' : 'light');
      mq.addEventListener('change', onChange);
      return () => mq.removeEventListener('change', onChange);
    } else {
      apply(settings.theme);
    }
  }, [settings.theme]);

  // Mirror the reading-typography settings into CSS variables on <html>.
  // Both .prose-body (rendered article) and CodeMirror's editor read these
  // through plain CSS — no React tree pass needed, no editor rebuild on
  // font tweaks. See "Reading typography" in context.md for the contract.
  useEffect(() => {
    const s = document.documentElement.style;
    s.setProperty('--reader-font-family', fontStack(settings.fontFamily));
    s.setProperty('--reader-font-size', `${settings.fontSize}px`);
    s.setProperty('--reader-line-height', String(settings.lineHeight));
  }, [settings.fontFamily, settings.fontSize, settings.lineHeight]);

  useEffect(() => { saveTabs(tabs); }, [tabs]);
  useEffect(() => { saveActiveIndex(activeIndex); }, [activeIndex]);

  const updateSettings = useCallback((next: Settings) => {
    setSettings(next);
    saveSettings(next);
  }, []);

  const sidebarTypes = useMemo(() => orderedTypes(settings), [settings]);

  // Multi-level list sort (QUA-63) — persisted globally in settings so it
  // sticks. Seed from the legacy single sortKey/sortDir for upgrading users;
  // coerce so a stale/corrupt value can't reach the comparator.
  const sortClauses = useMemo<SortClause[]>(() => {
    if (settings.sortClauses) return coerceSortClauses(settings.sortClauses);
    if (settings.sortKey && settings.sortKey !== 'default') {
      return coerceSortClauses([{ field: settings.sortKey, dir: settings.sortDir ?? 'desc' }]);
    }
    return [];
  }, [settings.sortClauses, settings.sortKey, settings.sortDir]);
  const onSortChange = useCallback((next: SortClause[]) => {
    setSettings(prev => {
      const merged: Settings = { ...prev, sortClauses: next };
      saveSettings(merged);
      return merged;
    });
  }, []);

  const onReorderTypes = useCallback((next: EntryType[]) => {
    setSettings(prev => {
      const merged: Settings = { ...prev, typeOrder: next };
      saveSettings(merged);
      return merged;
    });
  }, []);

  const onToggleSidebar = useCallback(() => {
    setSettings(prev => {
      const merged: Settings = { ...prev, sidebarCollapsed: !prev.sidebarCollapsed };
      saveSettings(merged);
      return merged;
    });
  }, []);

  // Cmd/Ctrl+K opens the global search palette.
  // Cmd/Ctrl+B toggles the leftmost main sidebar (VSCode-style).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K')) {
        e.preventDefault();
        setPaletteSourceType(null);
        setPaletteOpen(true);
      } else if ((e.metaKey || e.ctrlKey) && (e.key === 'b' || e.key === 'B')) {
        e.preventDefault();
        onToggleSidebar();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onToggleSidebar]);

  // File-browser data layer: the DB snapshot (/api/index) is just a metadata
  // cache loaded once on boot; the file system is the source of truth. We track
  // the mtime we last processed per file so cross-window / refocus syncs only
  // re-parse what actually changed.
  const entriesRef = useRef<Entry[] | null>(entries);
  entriesRef.current = entries;
  // Latest tab state, for the cross-page convergence check on focus (QUA-68).
  const tabsRef = useRef(tabs);
  tabsRef.current = tabs;
  const activeIndexRef = useRef(activeIndex);
  activeIndexRef.current = activeIndex;
  const knownMtimesRef = useRef<Map<string, number | null>>(new Map());
  const lastSyncMtimeRef = useRef(0);
  const syncingRef = useRef(false);
  const syncTimerRef = useRef<number | null>(null);
  const lastReconcileRef = useRef(0);

  // Cross-window / external freshness, the file-browser way. Pull only the
  // delta (files with mtime > lastSync) and live-parse just the ones whose
  // mtime actually changed vs what we last saw. A full listing is fetched only
  // when the server's total file count disagrees with ours — i.e. a deletion
  // (or odd add) happened — so the common no-op / edit sync ships almost nothing.
  const syncFromFiles = useCallback(() => {
    if (syncTimerRef.current != null) clearTimeout(syncTimerRef.current);
    syncTimerRef.current = window.setTimeout(async () => {
      syncTimerRef.current = null;
      if (syncingRef.current) return;
      syncingRef.current = true;
      try {
        const known = knownMtimesRef.current;
        const cur = entriesRef.current ?? [];
        const byPath = new Map(cur.map(e => [e.path, e]));
        let mutated = false;
        let maxMtime = lastSyncMtimeRef.current;

        // Parse only files new-or-changed vs `known`; upsert entries, drop
        // null-parses (non-entries), and record the mtime we processed.
        const processFiles = async (files: { path: string; mtime: number | null }[]) => {
          const toParse = files.filter(f => !known.has(f.path) || known.get(f.path) !== f.mtime);
          // Bounded concurrency: a large sync (e.g. after a git pull or a stale
          // index) can have thousands of changed files; firing them all at once
          // saturates the browser connection pool and stalls user clicks.
          const parsed = await mapPool(toParse, SYNC_FETCH_CONCURRENCY, async f => {
            try { return [f, await fetchEntry(f.path)] as const; }
            catch { return [f, undefined] as const; } // fetch failed → leave as-is
          });
          for (const [f, entry] of parsed) {
            if (entry === undefined) continue;
            known.set(f.path, f.mtime);
            if (f.mtime != null && f.mtime > maxMtime) maxMtime = f.mtime;
            if (entry === null) { if (byPath.delete(f.path)) mutated = true; }
            else { byPath.set(f.path, entry); mutated = true; }
          }
        };

        let delta;
        try { delta = await listFiles(lastSyncMtimeRef.current || undefined); }
        catch { return; } // keep current list on a transient failure
        await processFiles(delta.items);

        // Counts disagree → a deletion (or add with an older mtime) happened.
        // One full listing reconciles: parse anything still unknown, drop files
        // that no longer exist.
        if (delta.total !== known.size) {
          let full = null;
          try { full = await listFiles(); } catch {}
          if (full) {
            const fileSet = new Set(full.items.map(f => f.path));
            await processFiles(full.items);
            for (const p of Array.from(byPath.keys())) {
              if (!fileSet.has(p)) { byPath.delete(p); mutated = true; }
            }
            for (const p of Array.from(known.keys())) {
              if (!fileSet.has(p)) known.delete(p);
            }
          }
        }

        lastSyncMtimeRef.current = maxMtime;
        if (mutated) setEntries(Array.from(byPath.values()));
      } finally {
        syncingRef.current = false;
      }
    }, 250);
  }, []);

  useEffect(() => {
    fetchIndex().then(es => {
      setEntries(es);
      for (const e of es) knownMtimesRef.current.set(e.path, e.mtime ?? null);
      // Reconcile the cache against the live file system immediately — picks up
      // files added/changed/deleted since the last reindex (or while this window
      // was closed) without waiting for a focus/storage event.
      syncFromFiles();
    }).catch(e => {
      window.alert('加载索引失败：' + (e instanceof Error ? e.message : String(e)));
      setEntries([]);
    });
    fetchTranslationSlugs().then(s => setTranslationSlugs(new Set(s)));
  }, [syncFromFiles]);

  useEffect(() => {
    const unsubscribe = subscribeVaultChanges({
      onVaultChanged: syncFromFiles,
      onSettingsChanged: () => setSettings(loadSettings()),
    });
    const onVisible = () => {
      if (document.visibilityState !== 'visible') return;
      syncFromFiles();
      // QUA-68: converge the tab set across pages. Tabs persist in shared
      // localStorage, so another page may have changed them while this one was
      // unfocused — adopt the authoritative state instead of drifting apart.
      const incomingTabs = loadTabs();
      if (JSON.stringify(incomingTabs) !== JSON.stringify(tabsRef.current)) {
        setTabs(incomingTabs);
        setActiveIndex(loadActiveIndex(incomingTabs.length));
      } else {
        const incomingActive = loadActiveIndex(incomingTabs.length);
        if (incomingActive !== activeIndexRef.current) setActiveIndex(incomingActive);
      }
      // Also delta-sync the server FTS so quick search reflects external edits
      // the instant you switch back — best-effort, throttled so rapid window
      // toggles don't hammer it (the background watcher covers steady state).
      const now = Date.now();
      if (now - lastReconcileRef.current > 3000) {
        lastReconcileRef.current = now;
        reconcile().catch(() => {});
      }
    };
    window.addEventListener('focus', onVisible);
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      unsubscribe();
      window.removeEventListener('focus', onVisible);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [syncFromFiles]);

  const counts = useMemo(() => {
    const c: Record<string, number> = {};
    if (entries) for (const e of entries) c[e.type] = (c[e.type] ?? 0) + 1;
    return c;
  }, [entries]);

  const wikiIndex = useMemo(() => buildWikiIndex(entries ?? []), [entries]);
  // Built lazily — only while a search query is active. No-query list rendering
  // and optimistic writes therefore never pay the ~14k-entry index rebuild
  // (the NFKD-normalize-10-fields cost that made new-note feel slow).
  const hasQuery = query.trim() !== '';
  const searchIndex = useMemo(
    () => (hasQuery ? buildSearchIndex(entries ?? []) : []),
    [entries, hasQuery],
  );

  const annotationIndex = useMemo(() => {
    const m = new Map<string, Entry[]>();
    if (!entries) return m;
    for (const e of entries) {
      if (e.type !== 'note' || !e.annotates) continue;
      const list = m.get(e.annotates) ?? [];
      list.push(e);
      m.set(e.annotates, list);
    }
    return m;
  }, [entries]);

  const authorIndex = useMemo(() => {
    const m = new Map<string, Entry[]>();
    if (!entries) return m;
    for (const e of entries) {
      if (e.type !== 'paper-analysis' && e.type !== 'book-overview') continue;
      for (const name of splitAuthors(e.author)) {
        const k = name.toLowerCase();
        if (!m.has(k)) m.set(k, []);
        m.get(k)!.push(e);
      }
    }
    return m;
  }, [entries]);

  const entryByPath = useMemo(() => {
    const m = new Map<string, Entry>();
    if (entries) for (const e of entries) m.set(e.path, e);
    return m;
  }, [entries]);

  const activeTab: Tab | null = tabs[activeIndex] ?? tabs[0] ?? null;
  const activeTabContent: TabContent | null = activeTab ? activeContent(activeTab) : null;
  const activeListType: EntryType | null =
    activeTabContent && activeTabContent.kind === 'list' ? activeTabContent.type : null;
  const activeDocEntry: Entry | null =
    activeTabContent && activeTabContent.kind === 'doc' ? entryByPath.get(activeTabContent.path) ?? null : null;
  const trashActive = activeTabContent?.kind === 'trash';
  const themesActive = activeTabContent?.kind === 'themes';
  const activityActive = activeTabContent?.kind === 'activity';

  const themesCount = useMemo(() => {
    if (!entries) return 0;
    const s = new Set<string>();
    for (const e of entries) for (const t of (e.themes ?? [])) if (t) s.add(t);
    return s.size;
  }, [entries]);

  useEffect(() => {
    setLimit(300);
  }, [activeListType]);

  const typeEntries = useMemo(
    () => activeListType ? (entries ?? []).filter(e => e.type === activeListType) : [],
    [entries, activeListType]
  );

  const localFiltered = useMemo(() => {
    if (!activeListType) return [];
    // Multi-filter on plain entries — no search index needed for the common
    // no-query list path.
    const base = applyFilters(typeEntries, filters, filterMatch);
    const q = query.trim();
    // No query: apply the multi-sort (empty clause list leaves index order).
    if (!q) return sortEntriesMulti(base, sortClauses);
    // Query: rank via the (lazily-built) search index, restricted to this type
    // + the active filters. Keep relevance order unless the user picked a sort.
    const allowed = new Set(base.map(e => e.path));
    const docs = searchIndex.filter(doc => allowed.has(doc.entry.path));
    const ranked = searchDocuments(docs, q).map(result => result.entry);
    return sortClauses.length === 0 ? ranked : sortEntriesMulti(ranked, sortClauses);
  }, [typeEntries, searchIndex, query, filters, filterMatch, sortClauses, activeListType]);

  const listSearchKey = useMemo(() => JSON.stringify({
    q: query.trim(),
    type: activeListType,
    mode: searchMode,
  }), [query, activeListType, searchMode]);

  useEffect(() => {
    const q = query.trim();
    if (!activeListType || !q) {
      setListSearch(null);
      return;
    }

    const controller = new AbortController();
    setListSearch(prev => (
      prev?.key === listSearchKey
        ? { ...prev, loading: true, error: null }
        : { key: listSearchKey, entries: [], loading: true, error: null }
    ));

    const timer = window.setTimeout(() => {
      // Server FTS does pure text ranking; all field filters are applied
      // client-side after reconciliation so AND/OR clauses stay correct.
      searchServerIndex({
        q,
        type: activeListType,
        limit: 500,
        mode: searchMode,
        signal: controller.signal,
      })
        .then(items => {
          setListSearch({
            key: listSearchKey,
            entries: items.map(item => item.entry),
            loading: false,
            error: null,
          });
        })
        .catch(err => {
          if (controller.signal.aborted) return;
          setListSearch({
            key: listSearchKey,
            entries: localFiltered,
            loading: false,
            error: err instanceof Error ? err.message : String(err),
          });
        });
    }, 180);

    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
  }, [activeListType, query, searchMode, listSearchKey, localFiltered]);

  const filtered = useMemo(() => {
    if (!query.trim()) return localFiltered;
    const serverReady = listSearch && listSearch.key === listSearchKey && !listSearch.loading;
    if (!serverReady) return localFiltered;
    // The server FTS reads the (possibly stale) DB cache. Reconcile against the
    // live file-browser entries: keep server hits only if the path still exists
    // (drops deleted/renamed), remap to the fresh entry, then append live client
    // matches the stale index missed (e.g. just-created notes). Order: FTS rank
    // first (covers body matches), then any extra fresh matches.
    const seen = new Set<string>();
    const out: Entry[] = [];
    for (const hit of listSearch.entries) {
      const live = entryByPath.get(hit.path);
      if (live && live.type === activeListType && !seen.has(hit.path)) {
        out.push(live);
        seen.add(hit.path);
      }
    }
    for (const e of localFiltered) {
      if (!seen.has(e.path)) { out.push(e); seen.add(e.path); }
    }
    // Server FTS knows nothing about the field filters, so apply the whole
    // clause set (and any explicit sort) to the merged result. Empty sort
    // clause list keeps FTS rank.
    const refined = applyFilters(out, filters, filterMatch);
    return sortClauses.length === 0 ? refined : sortEntriesMulti(refined, sortClauses);
  }, [localFiltered, listSearch, listSearchKey, query, entryByPath, activeListType, filters, filterMatch, sortClauses]);

  // --- tab navigation: per-tab back/forward via history cursor ---

  const navigateInActiveTab = useCallback((content: TabContent) => {
    setTabs(prev => {
      const cur = prev[activeIndex];
      if (!cur) return prev;
      const next = prev.slice();
      next[activeIndex] = pushContent(cur, content);
      return next;
    });
  }, [activeIndex]);

  const openInNewTab = useCallback((content: TabContent) => {
    setTabs(prev => {
      // Dedupe DocTabs by path — list-tabs may reasonably be duplicated by user
      if (content.kind === 'doc') {
        const existing = prev.findIndex(t => {
          const c = activeContent(t);
          return c.kind === 'doc' && c.path === content.path;
        });
        if (existing >= 0) { setActiveIndex(existing); return prev; }
      }
      const next = [...prev, { history: [content], cursor: 0 } as Tab];
      if (next.length > MAX_TABS) next.splice(0, next.length - MAX_TABS);
      setActiveIndex(next.length - 1);
      return next;
    });
  }, []);

  const back = useCallback(() => {
    setTabs(prev => {
      const cur = prev[activeIndex];
      if (!cur || cur.cursor <= 0) return prev;
      const next = prev.slice();
      next[activeIndex] = { ...cur, cursor: cur.cursor - 1 };
      return next;
    });
  }, [activeIndex]);

  const forward = useCallback(() => {
    setTabs(prev => {
      const cur = prev[activeIndex];
      if (!cur || cur.cursor >= cur.history.length - 1) return prev;
      const next = prev.slice();
      next[activeIndex] = { ...cur, cursor: cur.cursor + 1 };
      return next;
    });
  }, [activeIndex]);

  const canBack = !!activeTab && activeTab.cursor > 0;
  const canForward = !!activeTab && activeTab.cursor < activeTab.history.length - 1;

  // Cmd+[ / Cmd+] keyboard shortcuts for back/forward.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey)) return;
      if (e.key === '[') { e.preventDefault(); back(); }
      else if (e.key === ']') { e.preventDefault(); forward(); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [back, forward]);

  // --- tab management actions ---

  const closeTab = useCallback((index: number) => {
    setTabs(prev => {
      if (prev.length <= 1) return prev;
      if (prev[index]?.pinned) return prev;
      const next = prev.filter((_, i) => i !== index);
      setActiveIndex(curIdx => {
        if (index === curIdx) return Math.max(0, index - 1);
        if (index < curIdx) return curIdx - 1;
        return curIdx;
      });
      return next;
    });
  }, []);

  const togglePin = useCallback((index: number) => {
    setTabs(prev => {
      const target = prev[index];
      if (!target) return prev;
      const toggled: Tab = { ...target, pinned: !target.pinned };
      const without = prev.filter((_, i) => i !== index);
      let insertAt: number;
      if (toggled.pinned) {
        insertAt = without.findIndex(t => !t.pinned);
        if (insertAt < 0) insertAt = without.length;
      } else {
        const lastPinned = (() => {
          for (let i = without.length - 1; i >= 0; i--) if (without[i].pinned) return i;
          return -1;
        })();
        insertAt = lastPinned + 1;
      }
      const next = [...without.slice(0, insertAt), toggled, ...without.slice(insertAt)];
      setActiveIndex(insertAt);
      return next;
    });
  }, []);

  const reorderTab = useCallback((from: number, to: number) => {
    setTabs(prev => {
      if (from === to || from < 0 || from >= prev.length || to < 0 || to >= prev.length) return prev;
      const next = prev.slice();
      const [item] = next.splice(from, 1);
      next.splice(to, 0, item);
      setActiveIndex(curIdx => {
        if (curIdx === from) return to;
        if (from < curIdx && curIdx <= to) return curIdx - 1;
        if (to <= curIdx && curIdx < from) return curIdx + 1;
        return curIdx;
      });
      return next;
    });
  }, []);

  const newTab = useCallback(() => {
    setTabs(prev => {
      const next = [...prev, { history: [{ kind: 'list', type: DEFAULT_TYPE }], cursor: 0 } as Tab];
      if (next.length > MAX_TABS) next.splice(0, next.length - MAX_TABS);
      setActiveIndex(next.length - 1);
      return next;
    });
    setQuery('');
  }, []);

  const activateTab = useCallback((index: number) => setActiveIndex(index), []);

  // --- semantic actions called by views ---

  // Sidebar type pick: replace current tab content (push to history) and reset
  // to a clean slate — clear query, all filters, and pagination.
  const openListType = useCallback((type: EntryType) => {
    navigateInActiveTab({ kind: 'list', type });
    setQuery('');
    setFilters([]);
    setFilterMatch('all');
    setLimit(300);
  }, [navigateInActiveTab]);

  const openTrash = useCallback(() => {
    navigateInActiveTab({ kind: 'trash' });
  }, [navigateInActiveTab]);

  const openThemes = useCallback(() => {
    navigateInActiveTab({ kind: 'themes' });
  }, [navigateInActiveTab]);

  const openActivity = useCallback(() => {
    navigateInActiveTab({ kind: 'activity' });
  }, [navigateInActiveTab]);

  // After a successful trash restore, the restored file is back under
  // vault/notes/. We don't have it in our in-memory entries until the index
  // rebuilds; show a hint that the page can be reloaded to see it.
  const onTrashRestored = useCallback((_restoredPath: string) => {
    void _restoredPath;
    // Best-effort: nudge the user; full integration would re-fetch /api/index.
    // For now do nothing — the file is on disk and will appear after next
    // `npm run build:index` + reload.
  }, []);

  // Card click: navigate in current tab. Cmd/Ctrl+click opens a new tab.
  // Matches Obsidian / browser muscle memory; consistent with how sidebar
  // type clicks and in-doc links behave.
  const openDoc = useCallback((entry: Entry, modifiers: { meta: boolean }) => {
    if (modifiers.meta) openInNewTab({ kind: 'doc', path: entry.path });
    else navigateInActiveTab({ kind: 'doc', path: entry.path });
  }, [openInNewTab, navigateInActiveTab]);

  // In-doc navigation (wikilink, chapter rail, back-to-book button): replace
  // current tab content so back/forward works as expected.
  const navigateInTab = useCallback((entry: Entry, _modifiers: { meta: boolean }) => {
    void _modifiers;
    navigateInActiveTab({ kind: 'doc', path: entry.path });
  }, [navigateInActiveTab]);

  // --- entry-level actions ---

  const onViewAll = useCallback((type: EntryType, q: string) => {
    setPaletteOpen(false);
    setQuery(q);                                    // preserve current query
    setLimit(300);                                  // reset pagination
    setFilters([]);                                 // clear unrelated filters
    setFilterMatch('all');
    navigateInActiveTab({ kind: 'list', type });
    // Do NOT call openListType(): it clears the query, which is the opposite of
    // what we want here.
  }, [navigateInActiveTab]);

  // Append a clause from a card / doc click (theme chip, author name). Switches
  // to the target list and adds the clause unless an identical one already
  // exists. Keeps any other active filters so clicks compose.
  const addFilterClause = useCallback((field: 'theme' | 'author', value: string, fromType?: EntryType) => {
    const targetType = fromType ?? activeListType;
    if (targetType) navigateInActiveTab({ kind: 'list', type: targetType });
    setFilters(prev => {
      if (prev.some(c => c.field === field && c.value === value)) return prev;
      return [...prev, makeClause(field, undefined, value)];
    });
    setQuery('');
    setLimit(300);
  }, [navigateInActiveTab, activeListType]);

  const applyThemeFilter = useCallback(
    (th: string, fromType?: EntryType) => addFilterClause('theme', th, fromType),
    [addFilterClause],
  );
  const applyAuthorFilter = useCallback(
    (name: string, fromType?: EntryType) => addFilterClause('author', name, fromType),
    [addFilterClause],
  );

  const onUpdated = useCallback((updated: Entry) => {
    setEntries(prev => prev ? prev.map(e => e.path === updated.path ? updated : e) : prev);
    bumpVaultVersion();
  }, []);

  // QUA-72: where a freshly-created note "lands". In external-editor mode the
  // built-in editor is fully out of the loop — we hand the file straight to the
  // external editor and do NOT open an in-app tab (an empty read-only tab would
  // be noise). The note still appears in the 笔记 list. Only if the launch fails
  // do we fall back to an in-app tab so the new note isn't stranded. With
  // external mode off, the note opens in the in-app CodeMirror editor as before.
  const revealNewNote = useCallback(async (path: string) => {
    if (settings.useExternalEditor) {
      try {
        await openInEditor(path, settings.externalEditor);
        return;
      } catch (e) {
        window.alert('在外部编辑器打开失败：' + (e instanceof Error ? e.message : String(e)));
        // fall through to an in-app tab so the created note isn't lost
      }
    }
    openInNewTab({ kind: 'doc', path });
  }, [settings.useExternalEditor, settings.externalEditor, openInNewTab]);

  const onCreateAnnotation = useCallback(async (target: Entry) => {
    const { path, body, title } = newAnnotationDraft(target);
    await postEntryText(path, body);
    const draftEntry = entryFromDraft(path, target, title);
    setEntries(prev => prev ? [...prev, draftEntry] : prev);
    bumpVaultVersion();
    await revealNewNote(path);
  }, [revealNewNote]);

  const onNewIdeaNote = useCallback(async () => {
    try {
      const { path, body, title } = newIdeaDraft();
      await postEntryText(path, body);
      const draft = ideaEntryFromDraft(path, title);
      setEntries(prev => prev ? [...prev, draft] : prev);
      bumpVaultVersion();
      await revealNewNote(path);
    } catch (e) {
      window.alert('新建 note 失败：' + (e instanceof Error ? e.message : String(e)));
    }
  }, [revealNewNote]);

  const onDelete = useCallback(async (target: Entry) => {
    await deleteEntry(target.path);
    setEntries(prev => prev ? prev.filter(e => e.path !== target.path) : prev);
    bumpVaultVersion();
    // Close any tab whose *current* content is the deleted entry. (We keep tabs
    // that merely reference it in history — back/forward will show StaleTab.)
    setTabs(prev => {
      const idx = prev.findIndex(t => {
        const c = activeContent(t);
        return c.kind === 'doc' && c.path === target.path;
      });
      if (idx < 0) return prev;
      if (prev.length <= 1) return [defaultTab()];
      const next = prev.filter((_, i) => i !== idx);
      setActiveIndex(curIdx => {
        if (idx === curIdx) return Math.max(0, idx - 1);
        if (idx < curIdx) return curIdx - 1;
        return curIdx;
      });
      return next;
    });
  }, []);

  // An entry is "editable" if it's a note, or any generated body when the user
  // opted in. QUA-72 then splits that into two paths: in-app CodeMirror vs. the
  // external editor. When useExternalEditor is on, the in-app editor is never
  // mounted (read-only render + "open externally" instead).
  const editable = activeDocEntry
    ? (activeDocEntry.type === 'note' || settings.allowEditLLMBody)
    : false;
  const editInApp = editable && !settings.useExternalEditor;
  const canEditExternally = editable && settings.useExternalEditor;

  // Throws on failure — the caller (ExternalOpenButton) surfaces it inline. We do
  // NOT window.alert here: a blocking modal would freeze the button's "正在打开…"
  // state until dismissed, which reads as a hang.
  const onOpenInEditor = useCallback(
    (target: Entry) => openInEditor(target.path, settings.externalEditor),
    [settings.externalEditor],
  );

  // Editor's reactive surface is just dark/light — font face & size flow
  // in through CSS vars on <html>, so changing them doesn't rebuild the
  // editor (preserves caret / undo / scroll).
  const editorTheme = useMemo(() => ({ dark: resolvedDark }), [resolvedDark]);

  if (!entries) return <div class="p-10 text-muted">加载索引中…</div>;

  return (
    <div class="h-screen flex bg-surface">
      <Sidebar
        entries={entries}
        counts={counts}
        types={sidebarTypes}
        collapsed={!!settings.sidebarCollapsed}
        activeType={activeListType}
        trashActive={trashActive}
        themesActive={themesActive}
        themesCount={themesCount}
        activityActive={activityActive}
        reindexing={reindexing}
        onSelectType={openListType}
        onReorderTypes={onReorderTypes}
        onToggleCollapse={onToggleSidebar}
        onOpenTrash={openTrash}
        onOpenThemes={openThemes}
        onOpenActivity={openActivity}
        onOpenSettings={() => setSettingsOpen(true)}
        onNewIdeaNote={onNewIdeaNote}
        onReindex={onReindex}
        onOpenSearch={() => { setPaletteSourceType(null); setPaletteOpen(true); }}
      />

      <div class="flex-1 min-w-0 flex flex-col">
        <TabBar
          tabs={tabs}
          activeIndex={activeIndex}
          entryByPath={entryByPath}
          onActivate={activateTab}
          onClose={closeTab}
          onNewTab={newTab}
          onTogglePin={togglePin}
          onReorder={reorderTab}
          onBack={back}
          onForward={forward}
          canBack={canBack}
          canForward={canForward}
        />

        {activeTabContent?.kind === 'list' && (
          <ListView
            entries={entries}
            type={activeTabContent.type}
            typeEntries={typeEntries}
            filtered={filtered}
            query={query}
            filters={filters}
            filterMatch={filterMatch}
            sortClauses={sortClauses}
            onFiltersChange={setFilters}
            onMatchChange={setFilterMatch}
            onSortChange={onSortChange}
            limit={limit}
            searchLoading={!!query.trim() && !!listSearch && listSearch.key === listSearchKey && listSearch.loading}
            searchError={listSearch && listSearch.key === listSearchKey ? listSearch.error : null}
            searchMode={searchMode}
            onToggleSearchMode={toggleSearchMode}
            onOpenSearch={() => { setPaletteSourceType(activeTabContent.type); setPaletteOpen(true); }}
            onClearQuery={() => setQuery('')}
            onLoadMore={() => setLimit(limit + 500)}
            onCardClick={openDoc}
            onThemeClick={(th) => applyThemeFilter(th, activeTabContent.type)}
            onAuthorClick={(name) => applyAuthorFilter(name, activeTabContent.type)}
          />
        )}

        {activeTabContent?.kind === 'doc' && (
          activeDocEntry
            ? (
              <DocView
                entry={activeDocEntry}
                entries={entries}
                authorIndex={authorIndex}
                annotationIndex={annotationIndex}
                wikiIndex={wikiIndex}
                editable={editInApp}
                canEditExternally={canEditExternally}
                editorTheme={editorTheme}
                citationFormat={settings.citationFormat}
                hasTranslation={translationSlugs.has(activeDocEntry.pdf_slug ?? '')}
                onNavigate={navigateInTab}
                onThemeClick={applyThemeFilter}
                onUpdated={onUpdated}
                onCreateAnnotation={onCreateAnnotation}
                onOpenInEditor={onOpenInEditor}
                onDelete={onDelete}
              />
            )
            : <StaleTab path={activeTabContent.path} onClose={() => closeTab(activeIndex)} />
        )}

        {activeTabContent?.kind === 'trash' && (
          <TrashView onRestored={onTrashRestored} />
        )}

        {activeTabContent?.kind === 'themes' && (
          <ThemesView entries={entries} onThemeClick={applyThemeFilter} />
        )}

        {activeTabContent?.kind === 'activity' && (
          <ActivityView entries={entries} />
        )}
      </div>

      {settingsOpen && (
        <SettingsPanel
          settings={settings}
          onChange={updateSettings}
          onClose={() => setSettingsOpen(false)}
        />
      )}

      <CommandPalette
        open={paletteOpen}
        documents={searchIndex}
        typeOrder={sidebarTypes}
        sourceType={paletteSourceType}
        query={query}
        searchMode={searchMode}
        onToggleSearchMode={toggleSearchMode}
        onSetSearchMode={setSearchMode}
        onClose={() => setPaletteOpen(false)}
        onPick={openDoc}
        onViewAll={onViewAll}
      />
    </div>
  );
}

function StaleTab({ path, onClose }: { path: string; onClose: () => void }) {
  return (
    <div class="flex-1 flex items-center justify-center text-muted text-sm">
      <div class="text-center">
        <div class="mb-2">{path} 已不在索引中</div>
        <button onClick={onClose} class="text-secondary underline">关闭 tab</button>
      </div>
    </div>
  );
}
