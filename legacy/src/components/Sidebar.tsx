import { useState } from 'preact/hooks';
import type { Entry, EntryType, TypeMeta } from '../types';
import { TypeIcon } from './TypeIcon';
import { Icon } from './Icon';
import PhLeaf from '~icons/ph/leaf';
import PhTag from '~icons/ph/tag';
import PhChartLineUp from '~icons/ph/chart-line-up';
import PhArrowsClockwise from '~icons/ph/arrows-clockwise';

interface Props {
  entries: Entry[];
  counts: Record<string, number>;
  /** Object types in user-saved order. Drag-reorder writes back through onReorderTypes. */
  types: TypeMeta[];
  /** True → render icon-only narrow rail (~56px). Toggled via Cmd+B or header chevron. */
  collapsed: boolean;
  /** Currently highlighted type — only set when the active tab is a ListTab. */
  activeType: EntryType | null;
  /** True when the active tab is the trash view. */
  trashActive: boolean;
  /** True when the active tab is the themes index view. */
  themesActive: boolean;
  /** Total distinct themes across the vault. */
  themesCount: number;
  /** True when the active tab is the activity heatmap view. */
  activityActive: boolean;
  /** True while a reindex is in flight; disables the button + spins the icon. */
  reindexing: boolean;
  onSelectType: (id: EntryType) => void;
  onReorderTypes: (next: EntryType[]) => void;
  onToggleCollapse: () => void;
  onOpenTrash: () => void;
  onOpenThemes: () => void;
  onOpenActivity: () => void;
  onOpenSettings: () => void;
  onNewIdeaNote: () => void;
  onReindex: () => void;
  onOpenSearch: () => void;
}

export function Sidebar({
  counts, types, collapsed, activeType, trashActive, themesActive, themesCount, activityActive, reindexing,
  onSelectType, onReorderTypes, onToggleCollapse,
  onOpenTrash, onOpenThemes, onOpenActivity,
  onOpenSettings, onNewIdeaNote, onReindex, onOpenSearch,
}: Props) {
  const [dragIndex, setDragIndex] = useState<number | null>(null);
  const [overIndex, setOverIndex] = useState<number | null>(null);

  const onDragStart = (i: number) => (e: DragEvent) => {
    setDragIndex(i);
    if (e.dataTransfer) {
      e.dataTransfer.effectAllowed = 'move';
      // Required for Firefox to start the drag.
      e.dataTransfer.setData('text/plain', String(i));
    }
  };
  const onDragOver = (i: number) => (e: DragEvent) => {
    if (dragIndex == null) return;
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = 'move';
    if (i !== overIndex) setOverIndex(i);
  };
  const onDragEnd = () => { setDragIndex(null); setOverIndex(null); };
  const onDrop = (i: number) => (e: DragEvent) => {
    e.preventDefault();
    if (dragIndex == null || dragIndex === i) { onDragEnd(); return; }
    const next = types.slice();
    const [moved] = next.splice(dragIndex, 1);
    next.splice(i, 0, moved);
    onReorderTypes(next.map(t => t.id));
    onDragEnd();
  };

  // Shared row class. In collapsed mode we drop the label, center contents,
  // and shrink the hit-target down to a square.
  const rowCls = (active: boolean) => collapsed
    ? `mx-auto flex items-center justify-center w-9 h-9 my-1 rounded-xl transition cursor-pointer ${
        active ? 'bg-accent-bg text-accent-text' : 'text-secondary hover:bg-hover/60'
      }`
    : `w-full text-left px-2.5 py-2 rounded-xl text-[12.5px] flex items-center gap-2.5 transition ${
        active ? 'bg-accent-bg text-accent-text font-medium' : 'text-secondary hover:bg-hover/60'
      }`;

  const widthCls = collapsed ? 'w-14' : 'w-60';

  return (
    <aside class={`${widthCls} shrink-0 bg-page border-r border-base flex flex-col text-primary`}>
      {/* Header: app name + collapse chevron. */}
      <div class={`border-b border-base flex items-center ${collapsed ? 'justify-center px-1 py-2.5' : 'justify-between px-4 py-2.5'}`}>
        {!collapsed && (
          <div class="min-w-0 flex items-center gap-2.5">
            <span class="shrink-0 w-7 h-7 rounded-[10px] bg-accent text-white flex items-center justify-center text-[14px]" aria-hidden="true"><PhLeaf width="1.2em" height="1.2em" /></span>
            <span class="text-[14px] font-bold tracking-[-0.01em] text-primary truncate">Marple</span>
          </div>
        )}
        <button
          onClick={onToggleCollapse}
          title={collapsed ? '展开侧栏 (Cmd+B)' : '折叠侧栏 (Cmd+B)'}
          aria-label={collapsed ? '展开侧栏' : '折叠侧栏'}
          class="text-muted hover:text-primary p-1 inline-flex items-center rounded hover:bg-hover/60"
        >
          <Icon name="sidebar" size={16} />
        </button>
      </div>

      {/* Quick actions: new note + super-search. Both share the same row style.
          Expanded height is pinned to 88px so this divider lines up exactly with
          the list-view header's bottom border across the sidebar/content seam —
          the buttons' 12.5px text otherwise yields a 88.5px fractional height
          that renders as a 1px step on Retina. */}
      <div class={`border-b border-base ${collapsed ? 'px-1 py-2' : 'px-2 py-2 h-[88px]'} space-y-0.5`}>
        <button
          onClick={onNewIdeaNote}
          title="新建独立 idea note"
          class={collapsed
            ? 'mx-auto flex items-center justify-center w-9 h-9 rounded-xl text-accent-text hover:bg-accent/15 transition'
            : 'w-full text-left px-2.5 py-2 rounded-xl text-[12.5px] bg-accent-bg text-accent-text font-medium hover:bg-accent/15 flex items-center gap-2.5 transition'
          }
        >
          <span class="shrink-0 inline-flex items-center justify-center w-4 h-4"><Icon name="plus" size={collapsed ? 16 : 14} class="text-accent-text" /></span>
          {!collapsed && <span>新建笔记</span>}
        </button>
        <button
          onClick={onOpenSearch}
          title="超级检索 (⌘K)"
          class={collapsed
            ? 'mx-auto flex items-center justify-center w-9 h-9 rounded-xl text-secondary hover:bg-hover/60 transition'
            : 'w-full text-left px-2.5 py-2 rounded-xl text-[12.5px] hover:bg-hover/60 flex items-center gap-2.5 text-secondary transition'
          }
        >
          <span class="shrink-0 inline-flex items-center justify-center w-4 h-4"><Icon name="magnifying-glass" size={collapsed ? 16 : 14} class="text-muted" /></span>
          {!collapsed && <span>超级检索</span>}
        </button>
      </div>

      <nav class={`flex-1 overflow-auto scrollbar-thin ${collapsed ? 'px-1 py-2' : 'px-2 py-3'}`}>
        {!collapsed && (
          <div class="text-[10px] uppercase tracking-wider text-muted font-semibold px-2 mb-1.5">物件</div>
        )}
        {types.map((t: TypeMeta, i: number) => {
          const active = t.id === activeType;
          const n = counts[t.id] ?? 0;
          const isDragging = dragIndex === i;
          const isOver = overIndex === i && dragIndex !== null && dragIndex !== i;
          return (
            <button
              key={t.id}
              draggable
              onDragStart={onDragStart(i)}
              onDragOver={onDragOver(i)}
              onDragEnter={onDragOver(i)}
              onDrop={onDrop(i)}
              onDragEnd={onDragEnd}
              onClick={() => onSelectType(t.id)}
              title={collapsed ? `${t.label} · ${n}` : '拖拽以调整顺序'}
              class={`${rowCls(active)} cursor-grab active:cursor-grabbing ${
                isDragging ? 'opacity-40' : ''
              } ${isOver ? 'ring-1 ring-accent' : ''}`}
            >
              <TypeIcon type={t.id} />
              {!collapsed && (
                <>
                  <span class="flex-1 truncate">{t.label}</span>
                  <span class={`text-[11px] tabular-nums ${active ? 'text-accent-text' : 'text-muted'}`}>{n}</span>
                </>
              )}
            </button>
          );
        })}

        {collapsed
          ? <div class="my-2 mx-3 border-t border-base" aria-hidden="true" />
          : <div class="text-[10px] uppercase tracking-wider text-muted font-semibold px-2 mt-4 mb-1.5">视图</div>
        }

        <button
          onClick={onOpenThemes}
          title={collapsed ? `主题 · ${themesCount}` : undefined}
          class={rowCls(themesActive)}
        >
          <span
            class="shrink-0 inline-flex items-center justify-center rounded-[0.33em] bg-accent-bg text-accent-text"
            style={{ minHeight: '1.3em', minWidth: '1.3em', height: '1.3em', width: '1.3em' }}
            aria-hidden="true"
          >
            <PhTag width="0.94em" height="0.94em" style={{ padding: '0.05em' }} />
          </span>
          {!collapsed && (
            <>
              <span class="flex-1 truncate">主题</span>
              <span class={`text-[11px] tabular-nums ${themesActive ? 'text-accent-text' : 'text-muted'}`}>{themesCount}</span>
            </>
          )}
        </button>
        <button
          onClick={onOpenActivity}
          title={collapsed ? '活动' : undefined}
          class={rowCls(activityActive)}
        >
          <span
            class="shrink-0 inline-flex items-center justify-center rounded-[0.33em] bg-accent-bg text-accent-text"
            style={{ minHeight: '1.3em', minWidth: '1.3em', height: '1.3em', width: '1.3em' }}
            aria-hidden="true"
          >
            <PhChartLineUp width="0.94em" height="0.94em" style={{ padding: '0.05em' }} />
          </span>
          {!collapsed && <span class="flex-1 truncate">活动</span>}
        </button>
      </nav>

      <div class={`border-t border-base ${collapsed ? 'px-1 py-2' : 'p-2'} space-y-0.5`}>
        <button
          onClick={onReindex}
          disabled={reindexing}
          title={collapsed
            ? (reindexing ? '索引中…' : '重建索引')
            : '重新扫描 vault/ 生成索引（处理新 paper / author 后用）'
          }
          class={collapsed
            ? 'mx-auto flex items-center justify-center w-9 h-9 rounded-xl text-secondary hover:bg-hover/60 disabled:opacity-50 disabled:cursor-wait'
            : 'w-full text-left px-2.5 py-2 rounded-xl text-[12.5px] flex items-center gap-2.5 text-secondary hover:bg-hover/60 disabled:opacity-50 disabled:cursor-wait'
          }
        >
          <span class="shrink-0 inline-flex items-center justify-center w-4 h-4">
            <PhArrowsClockwise
              width={collapsed ? 16 : 14} height={collapsed ? 16 : 14}
              class={`text-muted ${reindexing ? 'animate-spin' : ''}`}
            />
          </span>
          {!collapsed && <span class="flex-1">{reindexing ? '索引中…' : '重建索引'}</span>}
        </button>
        <button
          onClick={onOpenTrash}
          title={collapsed ? '回收站点' : '回收站点'}
          class={rowCls(trashActive)}
        >
          <span class="shrink-0 inline-flex items-center justify-center w-4 h-4"><Icon name="trash" size={collapsed ? 16 : 14} class={trashActive ? 'text-accent-text' : 'text-muted'} /></span>
          {!collapsed && <span class="flex-1">回收站点</span>}
        </button>
        <button
          onClick={onOpenSettings}
          title={collapsed ? '系统设置' : undefined}
          class={collapsed
            ? 'mx-auto flex items-center justify-center w-9 h-9 rounded-xl text-secondary hover:bg-hover/60'
            : 'w-full text-left px-2.5 py-2 rounded-xl text-[12.5px] flex items-center gap-2.5 text-secondary hover:bg-hover/60'
          }
        >
          <span class="shrink-0 inline-flex items-center justify-center w-4 h-4"><Icon name="gear" size={collapsed ? 16 : 14} class="text-muted" /></span>
          {!collapsed && <span class="flex-1">系统设置</span>}
        </button>
      </div>
    </aside>
  );
}
