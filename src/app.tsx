import { useState, useEffect, useMemo, useCallback } from 'preact/hooks';
import type { Entry, EntryType, Tab, TabContent } from './types';
import { activeContent } from './types';
import { buildWikiIndex, splitAuthors } from './wiki';
import { ListView } from './components/ListView';
import { DocView } from './components/DocView';
import { SettingsPanel } from './components/SettingsPanel';
import { Sidebar } from './components/Sidebar';
import { TabBar } from './components/TabBar';
import {
  postEntryText, newAnnotationDraft, entryFromDraft, deleteEntry,
  newIdeaDraft, ideaEntryFromDraft,
} from './api';
import { loadSettings, saveSettings, type Settings } from './settings';

const TABS_KEY = 'qua-reader-tabs-v3';
const ACTIVE_KEY = 'qua-reader-active-tab';
const MAX_TABS = 16;
const MAX_HISTORY = 50;
const DEFAULT_TYPE: EntryType = 'paper-analysis';

function defaultTab(): Tab {
  return { history: [{ kind: 'list', type: DEFAULT_TYPE }], cursor: 0 };
}

function loadTabs(): Tab[] {
  try {
    const raw = localStorage.getItem(TABS_KEY);
    if (!raw) return [defaultTab()];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed) || parsed.length === 0) return [defaultTab()];
    const clean = parsed.filter((t: unknown): t is Tab => {
      if (!t || typeof t !== 'object') return false;
      const obj = t as Record<string, unknown>;
      if (!Array.isArray(obj.history) || typeof obj.cursor !== 'number') return false;
      return obj.history.every((c: unknown) => {
        if (!c || typeof c !== 'object') return false;
        const cc = c as Record<string, unknown>;
        return (cc.kind === 'list' && typeof cc.type === 'string')
            || (cc.kind === 'doc' && typeof cc.path === 'string');
      });
    });
    return clean.length > 0 ? clean : [defaultTab()];
  } catch {
    return [defaultTab()];
  }
}

function loadActiveIndex(): number {
  try {
    const raw = localStorage.getItem(ACTIVE_KEY);
    const n = raw == null ? 0 : parseInt(raw, 10);
    return Number.isFinite(n) && n >= 0 ? n : 0;
  } catch { return 0; }
}

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
  const [query, setQuery] = useState('');
  const [minRating, setMinRating] = useState(0);
  const [themeFilter, setThemeFilter] = useState<string | null>(null);
  const [limit, setLimit] = useState(300);
  const [settings, setSettings] = useState<Settings>(() => loadSettings());
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [tabs, setTabs] = useState<Tab[]>(() => loadTabs());
  const [activeIndex, setActiveIndex] = useState<number>(() => loadActiveIndex());

  useEffect(() => {
    try { localStorage.setItem(TABS_KEY, JSON.stringify(tabs)); } catch {}
  }, [tabs]);
  useEffect(() => {
    try { localStorage.setItem(ACTIVE_KEY, String(activeIndex)); } catch {}
  }, [activeIndex]);

  const updateSettings = useCallback((next: Settings) => {
    setSettings(next);
    saveSettings(next);
  }, []);

  useEffect(() => {
    fetch('data/index.json').then(r => r.json()).then(setEntries);
  }, []);

  const counts = useMemo(() => {
    const c: Record<string, number> = {};
    if (entries) for (const e of entries) c[e.type] = (c[e.type] ?? 0) + 1;
    return c;
  }, [entries]);

  const wikiIndex = useMemo(() => buildWikiIndex(entries ?? []), [entries]);

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

  useEffect(() => { setLimit(300); setThemeFilter(null); }, [activeListType]);

  const typeEntries = useMemo(
    () => activeListType ? (entries ?? []).filter(e => e.type === activeListType) : [],
    [entries, activeListType]
  );

  const filtered = useMemo(() => {
    if (!activeListType) return [];
    const q = query.trim().toLowerCase();
    return typeEntries.filter(e => {
      if (minRating && (e.rating_score || 0) < minRating) return false;
      if (themeFilter && !(e.themes ?? []).some(t => t === themeFilter)) return false;
      if (!q) return true;
      const hay = [
        e.title, e.author, e.preview, e.source, e.topic,
        ...(e.themes ?? []),
      ].filter(Boolean).join(' ').toLowerCase();
      return hay.includes(q);
    });
  }, [typeEntries, query, minRating, themeFilter, activeListType]);

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

  // Sidebar type pick: replace current tab content (push to history).
  const openListType = useCallback((type: EntryType) => {
    navigateInActiveTab({ kind: 'list', type });
    setQuery('');
  }, [navigateInActiveTab]);

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

  const applyThemeFilter = useCallback((th: string, fromType?: EntryType) => {
    const targetType = fromType ?? activeListType;
    if (targetType) navigateInActiveTab({ kind: 'list', type: targetType });
    setThemeFilter(th);
    setQuery('');
    setLimit(300);
  }, [navigateInActiveTab, activeListType]);

  const onUpdated = useCallback((updated: Entry) => {
    setEntries(prev => prev ? prev.map(e => e.path === updated.path ? updated : e) : prev);
  }, []);

  const onCreateAnnotation = useCallback(async (target: Entry) => {
    const { path, body, title } = newAnnotationDraft(target);
    await postEntryText(path, body);
    const draftEntry = entryFromDraft(path, target, title);
    setEntries(prev => prev ? [...prev, draftEntry] : prev);
    openInNewTab({ kind: 'doc', path });
  }, [openInNewTab]);

  const onNewIdeaNote = useCallback(async () => {
    try {
      const { path, body, title } = newIdeaDraft();
      await postEntryText(path, body);
      const draft = ideaEntryFromDraft(path, title);
      setEntries(prev => prev ? [...prev, draft] : prev);
      openInNewTab({ kind: 'doc', path });
    } catch (e) {
      window.alert('新建 note 失败：' + (e instanceof Error ? e.message : String(e)));
    }
  }, [openInNewTab]);

  const onDelete = useCallback(async (target: Entry) => {
    await deleteEntry(target.path);
    setEntries(prev => prev ? prev.filter(e => e.path !== target.path) : prev);
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

  const editable = activeDocEntry
    ? (activeDocEntry.type === 'note' || settings.allowEditLLMBody)
    : false;
  const editorTheme = useMemo(
    () => ({
      fontFamily: settings.fontFamily,
      fontSize: settings.fontSize,
      lineHeight: settings.lineHeight,
    }),
    [settings.fontFamily, settings.fontSize, settings.lineHeight],
  );

  if (!entries) return <div class="p-10 text-stone-500">加载索引中…</div>;

  return (
    <div class="h-screen flex bg-white">
      <Sidebar
        entries={entries}
        counts={counts}
        activeType={activeListType}
        onSelectType={openListType}
        onOpenSettings={() => setSettingsOpen(true)}
        onNewIdeaNote={onNewIdeaNote}
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
            minRating={minRating}
            themeFilter={themeFilter}
            limit={limit}
            onQueryChange={setQuery}
            onMinRatingChange={setMinRating}
            onClearTheme={() => setThemeFilter(null)}
            onLoadMore={() => setLimit(limit + 500)}
            onCardClick={openDoc}
            onThemeClick={(th) => applyThemeFilter(th, activeTabContent.type)}
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
                editable={editable}
                editorTheme={editorTheme}
                onNavigate={navigateInTab}
                onThemeClick={applyThemeFilter}
                onUpdated={onUpdated}
                onCreateAnnotation={onCreateAnnotation}
                onDelete={onDelete}
              />
            )
            : <StaleTab path={activeTabContent.path} onClose={() => closeTab(activeIndex)} />
        )}
      </div>

      {settingsOpen && (
        <SettingsPanel
          settings={settings}
          onChange={updateSettings}
          onClose={() => setSettingsOpen(false)}
        />
      )}
    </div>
  );
}

function StaleTab({ path, onClose }: { path: string; onClose: () => void }) {
  return (
    <div class="flex-1 flex items-center justify-center text-stone-500 text-sm">
      <div class="text-center">
        <div class="mb-2">{path} 已不在索引中</div>
        <button onClick={onClose} class="text-stone-700 underline">关闭 tab</button>
      </div>
    </div>
  );
}
