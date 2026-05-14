import { useState, useEffect, useMemo, useCallback } from 'preact/hooks';
import type { Entry, EntryType } from './types';
import { TYPES } from './types';
import { buildWikiIndex, splitAuthors } from './wiki';
import { Card } from './components/Card';
import { Dashboard } from './components/Dashboard';
import { Reader } from './components/Reader';
import { SettingsPanel } from './components/SettingsPanel';
import { postEntryText, newAnnotationDraft, entryFromDraft, deleteEntry } from './api';
import { loadSettings, saveSettings, type Settings } from './settings';

export function App() {
  const [entries, setEntries] = useState<Entry[] | null>(null);
  const [type, setType] = useState<EntryType>('paper-analysis');
  const [query, setQuery] = useState('');
  const [minRating, setMinRating] = useState(0);
  const [themeFilter, setThemeFilter] = useState<string | null>(null);
  const [open, setOpen] = useState<Entry | null>(null);
  const [limit, setLimit] = useState(300);
  const [settings, setSettings] = useState<Settings>(() => loadSettings());
  const [settingsOpen, setSettingsOpen] = useState(false);

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

  // target-path → notes that annotate it. Empty array if none.
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

  const typeEntries = useMemo(
    () => (entries ?? []).filter(e => e.type === type),
    [entries, type]
  );

  const filtered = useMemo(() => {
    if (!entries) return [];
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
  }, [typeEntries, query, minRating, themeFilter, entries]);

  const visible = query ? filtered : filtered.slice(0, limit);
  const isFiltered = !!(query || themeFilter || minRating);

  const switchType = useCallback((id: EntryType) => {
    setType(id); setLimit(300); setThemeFilter(null);
  }, []);

  const applyThemeFilter = useCallback((th: string, fromType?: EntryType) => {
    if (fromType) setType(fromType);
    setThemeFilter(th); setQuery(''); setLimit(300);
  }, []);

  const onUpdated = useCallback((updated: Entry) => {
    setEntries(prev => prev ? prev.map(e => e.path === updated.path ? updated : e) : prev);
    setOpen(prev => prev && prev.path === updated.path ? updated : prev);
  }, []);

  const onCreateAnnotation = useCallback(async (target: Entry) => {
    const { path, body, title } = newAnnotationDraft(target);
    await postEntryText(path, body);
    const draftEntry = entryFromDraft(path, target, title);
    setEntries(prev => prev ? [...prev, draftEntry] : prev);
    setOpen(draftEntry);
  }, []);

  const onDelete = useCallback(async (target: Entry) => {
    await deleteEntry(target.path);
    setEntries(prev => prev ? prev.filter(e => e.path !== target.path) : prev);
    setOpen(null);
  }, []);

  const editable = open
    ? (open.type === 'note' || settings.allowEditLLMBody)
    : false;

  if (!entries) return <div class="p-10 text-stone-500">加载索引中…</div>;

  return (
    <div class="min-h-screen">
      <header class="bg-white/90 backdrop-blur border-b border-stone-200 sticky top-0 z-20">
        <div class="max-w-[1600px] mx-auto px-5 py-3 flex items-center gap-4 flex-wrap">
          <div class="font-semibold text-base tracking-tight">qua <span class="text-stone-400">reader</span></div>
          <nav class="flex gap-1">
            {TYPES.map(t => (
              <button
                onClick={() => switchType(t.id)}
                class={`px-2.5 py-1 rounded text-[12px] transition ${type === t.id ? 'bg-stone-900 text-white' : 'text-stone-600 hover:bg-stone-100'}`}
              >
                {t.label} <span class="opacity-60 tabular-nums">{counts[t.id] ?? 0}</span>
              </button>
            ))}
          </nav>
          <input
            type="search"
            placeholder="搜索 标题 / 作者 / 主题 / 正文摘要…"
            value={query}
            onInput={e => setQuery((e.target as HTMLInputElement).value)}
            class="flex-1 min-w-[200px] px-3 py-1.5 border border-stone-300 rounded text-[13px] focus:outline-none focus:border-stone-500 bg-white"
          />
          <div class="flex items-center gap-1 text-[11px] text-stone-600">
            <span>评分 ≥</span>
            {[0, 1, 2, 3, 4].map(n => (
              <button
                onClick={() => setMinRating(n)}
                class={`px-1.5 py-0.5 rounded ${minRating === n ? 'bg-stone-900 text-white' : 'hover:bg-stone-100'}`}
              >{n || '·'}</button>
            ))}
          </div>
          <div class="text-[11px] text-stone-500 tabular-nums">{filtered.length} / {counts[type] ?? 0}</div>
          <button
            onClick={() => setSettingsOpen(true)}
            class="text-stone-500 hover:text-stone-900 px-1.5 py-0.5 rounded hover:bg-stone-100"
            title="设置"
          >⚙</button>
        </div>
        {themeFilter && (
          <div class="max-w-[1600px] mx-auto px-5 pb-2 flex items-center gap-2">
            <span class="text-[11px] text-stone-500">主题筛选</span>
            <button
              onClick={() => setThemeFilter(null)}
              class="text-[11px] px-2 py-0.5 rounded bg-amber-100 text-amber-800 border border-amber-200 hover:bg-amber-200 transition"
            >
              {themeFilter} <span class="text-amber-600 ml-1">✕</span>
            </button>
          </div>
        )}
      </header>
      <main class="max-w-[1600px] mx-auto px-5 py-4">
        {!isFiltered && (
          <Dashboard
            type={type}
            typeEntries={typeEntries}
            onThemeClick={(th) => applyThemeFilter(th, type)}
            onOpen={setOpen}
          />
        )}
        {filtered.length === 0
          ? <div class="text-sm text-stone-500 py-20 text-center">没有匹配的条目</div>
          : (
            <>
              <div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-2.5">
                {visible.map(e => <Card entry={e} onClick={setOpen} key={e.path} />)}
              </div>
              {!query && !themeFilter && filtered.length > limit && (
                <div class="text-center mt-6">
                  <button
                    onClick={() => setLimit(limit + 500)}
                    class="px-4 py-2 bg-white border border-stone-300 rounded text-sm hover:bg-stone-50"
                  >
                    再加载 500 ( 已显示 {limit} / {filtered.length} )
                  </button>
                </div>
              )}
            </>
          )
        }
      </main>
      <Reader
        entry={open}
        entries={entries}
        authorIndex={authorIndex}
        annotationIndex={annotationIndex}
        wikiIndex={wikiIndex}
        editable={editable}
        onClose={() => setOpen(null)}
        onNavigate={setOpen}
        onThemeClick={applyThemeFilter}
        onUpdated={onUpdated}
        onCreateAnnotation={onCreateAnnotation}
        onDelete={onDelete}
      />
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
