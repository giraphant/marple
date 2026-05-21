import { useState, useRef, useCallback, useEffect } from 'preact/hooks';
import type { ComponentChildren } from 'preact';
import type { Entry } from '../types';
import type { DocStats } from '../doc-stats';
import {
  loadDocPanelPrefs, saveDocPanelPrefs, clampPanelWidth,
  type DocPanelTab,
} from '../doc-panel';
import { Icon } from './Icon';

/** A heading shown in the 目录 tab. `key` is opaque to the panel — DocView maps
 *  it back to a DOM element (read mode) or a source line (edit mode). */
export interface PanelHeading {
  level: number;
  text: string;
  key: string;
}

export interface PanelBookContext {
  overview: Entry | null;
  chapters: Entry[];
}

interface Props {
  headings: PanelHeading[];
  activeHeadingKey: string | null;
  onHeadingClick: (key: string) => void;
  bookContext: PanelBookContext | null;
  activeEntryPath: string;
  onNavigate: (entry: Entry, modifiers: { meta: boolean }) => void;
  stats: DocStats;
  /** The PropertyPanel element, rendered in the 信息 tab (zero coupling). */
  info: ComponentChildren;
}

const TABS: { id: DocPanelTab; icon: 'list-bullets' | 'info' | 'chart-bar'; label: string }[] = [
  { id: 'toc', icon: 'list-bullets', label: '目录' },
  { id: 'info', icon: 'info', label: '信息' },
  { id: 'stats', icon: 'chart-bar', label: '统计' },
];

export function RightPanel({
  headings, activeHeadingKey, onHeadingClick,
  bookContext, activeEntryPath, onNavigate, stats, info,
}: Props) {
  const [prefs, setPrefs] = useState(() => loadDocPanelPrefs());
  const { tab, collapsed, width } = prefs;

  const persist = useCallback((next: typeof prefs) => {
    setPrefs(next);
    saveDocPanelPrefs(next);
  }, []);

  const selectTab = (id: DocPanelTab) => persist({ ...prefs, tab: id, collapsed: false });
  const setCollapsed = (c: boolean) => persist({ ...prefs, collapsed: c });

  // --- width drag (handle on the panel's left edge) ---
  const dragRef = useRef<{ startX: number; startWidth: number } | null>(null);
  const onDragMove = useCallback((e: PointerEvent) => {
    const d = dragRef.current;
    if (!d) return;
    // Panel is on the right, so dragging left (smaller clientX) widens it.
    setPrefs(p => ({ ...p, width: clampPanelWidth(d.startWidth + (d.startX - e.clientX)) }));
  }, []);
  const onDragEnd = useCallback(() => {
    dragRef.current = null;
    window.removeEventListener('pointermove', onDragMove);
    window.removeEventListener('pointerup', onDragEnd);
    setPrefs(p => { saveDocPanelPrefs(p); return p; });
  }, [onDragMove]);
  const onDragStart = useCallback((e: PointerEvent) => {
    e.preventDefault();
    dragRef.current = { startX: e.clientX, startWidth: width };
    window.addEventListener('pointermove', onDragMove);
    window.addEventListener('pointerup', onDragEnd);
  }, [width, onDragMove, onDragEnd]);
  useEffect(() => () => {
    window.removeEventListener('pointermove', onDragMove);
    window.removeEventListener('pointerup', onDragEnd);
  }, [onDragMove, onDragEnd]);

  if (collapsed) {
    return (
      <aside class="shrink-0 w-9 border-l border-base bg-page/60 flex flex-col items-center py-2 gap-1">
        <button
          onClick={() => setCollapsed(false)}
          title="展开面板"
          class="p-1.5 rounded-lg text-muted hover:text-primary hover:bg-surface-2"
        ><Icon name="caret-left" size={14} /></button>
        <div class="w-5 border-t border-base my-1" />
        {TABS.map(t => (
          <button
            key={t.id}
            onClick={() => selectTab(t.id)}
            title={t.label}
            class="p-1.5 rounded-lg text-muted hover:text-primary hover:bg-surface-2"
          ><Icon name={t.icon} size={15} /></button>
        ))}
      </aside>
    );
  }

  return (
    <aside
      class="relative shrink-0 border-l border-base bg-page/60 flex flex-col min-h-0"
      style={{ width: `${width}px` }}
    >
      <div
        onPointerDown={onDragStart}
        title="拖拽调整宽度"
        class="absolute left-0 top-0 bottom-0 w-1.5 -ml-0.5 cursor-col-resize hover:bg-accent/30 z-10"
      />
      <div class="flex items-center gap-1 px-2.5 py-2 border-b border-base shrink-0">
        {TABS.map(t => (
          <button
            key={t.id}
            onClick={() => selectTab(t.id)}
            title={t.label}
            aria-label={t.label}
            class={`p-1.5 rounded-lg transition ${
              tab === t.id
                ? 'bg-accent-bg text-accent-text'
                : 'text-muted hover:text-primary hover:bg-surface-2'
            }`}
          ><Icon name={t.icon} size={15} /></button>
        ))}
        <div class="flex-1" />
        <button
          onClick={() => setCollapsed(true)}
          title="折叠面板"
          class="p-1.5 rounded-lg text-muted hover:text-primary hover:bg-surface-2"
        ><Icon name="caret-right" size={14} /></button>
      </div>

      <div class="flex-1 overflow-auto scrollbar-thin min-h-0">
        {tab === 'toc' && (
          <TocTab
            headings={headings}
            activeHeadingKey={activeHeadingKey}
            onHeadingClick={onHeadingClick}
            bookContext={bookContext}
            activeEntryPath={activeEntryPath}
            onNavigate={onNavigate}
          />
        )}
        {tab === 'info' && info}
        {tab === 'stats' && <StatsTab stats={stats} />}
      </div>
    </aside>
  );
}

function TocTab({
  headings, activeHeadingKey, onHeadingClick, bookContext, activeEntryPath, onNavigate,
}: {
  headings: PanelHeading[];
  activeHeadingKey: string | null;
  onHeadingClick: (key: string) => void;
  bookContext: PanelBookContext | null;
  activeEntryPath: string;
  onNavigate: (entry: Entry, modifiers: { meta: boolean }) => void;
}) {
  const hasBook = !!(bookContext && (bookContext.overview || bookContext.chapters.length));
  // 本页大纲跳过文档标题级 H1(标题已在文档头),从其下一级开始;缩进按"最浅一级"归零,
  // 标准纯 H2 文档即平铺无缩进,只有出现 H3+ 子节时才相对缩进。仅当确有更深级标题时
  // 才过滤 H1,以免把"只有 H1"的文档大纲清空。
  const hasSub = headings.some(h => h.level > 1);
  const pageHeadings = hasSub ? headings.filter(h => h.level > 1) : headings;
  const minLevel = pageHeadings.reduce((m, h) => Math.min(m, h.level), 99);
  if (!hasBook && pageHeadings.length === 0) {
    return <div class="px-4 py-6 text-[12px] text-muted">无目录</div>;
  }
  return (
    <div class="py-2">
      {hasBook && (
        <div class="px-2 pb-2 mb-1 border-b border-base">
          <SectionLabel>本书</SectionLabel>
          {bookContext!.overview && (
            <NavRow
              label="概述"
              active={activeEntryPath === bookContext!.overview.path}
              onClick={(ev) => onNavigate(bookContext!.overview!, { meta: ev.metaKey || ev.ctrlKey })}
            />
          )}
          {bookContext!.chapters.map(c => (
            <NavRow
              key={c.path}
              label={c.title || c.path.split('/').pop()!.replace(/\.md$/, '')}
              active={c.path === activeEntryPath}
              onClick={(ev) => onNavigate(c, { meta: ev.metaKey || ev.ctrlKey })}
            />
          ))}
        </div>
      )}
      {pageHeadings.length > 0 ? (
        <div class="px-2">
          {hasBook && <SectionLabel>本页</SectionLabel>}
          {pageHeadings.map(h => (
            <button
              key={h.key}
              onClick={() => onHeadingClick(h.key)}
              title={h.text}
              style={{ paddingLeft: `${0.5 + Math.max(0, h.level - minLevel) * 0.75}rem` }}
              class={`w-full text-left py-1.5 pr-2 rounded-lg text-[12px] leading-snug truncate transition ${
                activeHeadingKey === h.key
                  ? 'bg-accent-bg text-accent-text font-medium'
                  : 'text-secondary hover:bg-surface-2 hover:text-primary'
              }`}
            >{h.text}</button>
          ))}
        </div>
      ) : hasBook ? null : (
        <div class="px-4 py-2 text-[12px] text-muted">本页无标题</div>
      )}
    </div>
  );
}

function StatsTab({ stats }: { stats: DocStats }) {
  const rows: [string, string][] = [
    ['字符', String(stats.chars)],
    ['不计空格', String(stats.charsNoSpace)],
    ['字数', String(stats.words)],
    ['段落', String(stats.paragraphs)],
    ['预计阅读', stats.minutes > 0 ? `${stats.minutes} 分钟` : '—'],
  ];
  return (
    <div class="p-5">
      <div class="text-[11px] uppercase tracking-wider text-muted font-semibold mb-2">统计</div>
      <dl class="space-y-1.5 text-[12px]">
        {rows.map(([k, v]) => (
          <div key={k} class="flex items-baseline justify-between gap-3">
            <dt class="text-muted">{k}</dt>
            <dd class="text-secondary tabular-nums">{v}</dd>
          </div>
        ))}
      </dl>
    </div>
  );
}

function SectionLabel({ children }: { children: ComponentChildren }) {
  return <div class="sticky top-0 z-10 bg-page/95 backdrop-blur-sm text-[11px] uppercase tracking-wider text-muted font-semibold px-2 py-1.5">{children}</div>;
}

function NavRow({ label, active, onClick }: {
  label: string;
  active: boolean;
  onClick: (ev: MouseEvent) => void;
}) {
  return (
    <button
      onClick={onClick}
      title={label}
      class={`w-full text-left px-2.5 py-2 rounded-lg text-[12px] leading-snug truncate transition ${
        active ? 'bg-accent-bg text-accent-text font-medium' : 'text-secondary hover:bg-surface-2 hover:text-primary'
      }`}
    >{label}</button>
  );
}
