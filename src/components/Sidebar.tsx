import { useState } from 'preact/hooks';
import type { Entry, EntryType, TypeMeta } from '../types';
import { TypeIcon } from './TypeIcon';
import { Icon } from './Icon';
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
    ? `mx-auto flex items-center justify-center w-9 h-9 my-0.5 rounded transition cursor-pointer ${
        active ? 'bg-inverse text-inverse-fg' : 'text-secondary hover:bg-hover/60'
      }`
    : `w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 transition ${
        active ? 'bg-inverse text-inverse-fg' : 'text-secondary hover:bg-hover/60'
      }`;

  const widthCls = collapsed ? 'w-14' : 'w-60';

  return (
    <aside class={`${widthCls} shrink-0 bg-page border-r border-base flex flex-col text-primary transition-[width] duration-150`}>
      {/* Header: app name + collapse chevron. */}
      <div class={`border-b border-base flex items-center ${collapsed ? 'justify-center px-1 py-3' : 'justify-between px-4 py-3'}`}>
        {!collapsed && (
          <div class="min-w-0">
            <div class="text-[13px] font-semibold tracking-tight text-primary">qua</div>
            <div class="text-[10px] text-muted uppercase tracking-wider mt-0.5">reader</div>
          </div>
        )}
        <div class="flex items-center gap-1">
          <button
            onClick={onOpenSearch}
            title="超级检索 (⌘K)"
            aria-label="超级检索"
            class="text-muted hover:text-primary p-1 inline-flex items-center rounded hover:bg-hover/60"
          >
            <Icon name="magnifying-glass" size={14} />
          </button>
          <button
            onClick={onToggleCollapse}
            title={collapsed ? '展开侧栏 (Cmd+B)' : '折叠侧栏 (Cmd+B)'}
            aria-label={collapsed ? '展开侧栏' : '折叠侧栏'}
            class="text-muted hover:text-primary p-1 inline-flex items-center rounded hover:bg-hover/60"
          >
            <Icon name={collapsed ? 'caret-right' : 'caret-left'} size={14} />
          </button>
        </div>
      </div>

      {/* New idea note. */}
      <div class={`border-b border-base ${collapsed ? 'px-1 py-2' : 'px-2 py-2'} space-y-0.5`}>
        <button
          onClick={onNewIdeaNote}
          title="新建独立 idea note"
          class={collapsed
            ? 'mx-auto flex items-center justify-center w-9 h-9 rounded text-secondary hover:bg-hover/60'
            : 'w-full text-left px-2 py-1.5 rounded text-[12px] hover:bg-hover/60 flex items-center gap-2 text-secondary'
          }
        >
          <Icon name="plus" size={collapsed ? 16 : 13} class="text-muted" />
          {!collapsed && <span>新建 note</span>}
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
              } ${isOver ? 'ring-1 ring-amber-400' : ''}`}
            >
              <TypeIcon type={t.id} />
              {!collapsed && (
                <>
                  <span class="flex-1 truncate">{t.label}</span>
                  <span class={`text-[11px] tabular-nums ${active ? 'text-white/70' : 'text-muted'}`}>{n}</span>
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
            class="shrink-0 inline-flex items-center justify-center rounded-[0.33em] bg-amber-100 text-amber-700 dark:text-amber-400 dark:bg-amber-950/40 dark:text-amber-300"
            style={{ minHeight: '1.3em', minWidth: '1.3em', height: '1.3em', width: '1.3em' }}
            aria-hidden="true"
          >
            <PhTag width="0.94em" height="0.94em" style={{ padding: '0.05em' }} />
          </span>
          {!collapsed && (
            <>
              <span class="flex-1 truncate">主题</span>
              <span class={`text-[11px] tabular-nums ${themesActive ? 'text-white/70' : 'text-muted'}`}>{themesCount}</span>
            </>
          )}
        </button>
        <button
          onClick={onOpenActivity}
          title={collapsed ? '活动' : undefined}
          class={rowCls(activityActive)}
        >
          <span
            class="shrink-0 inline-flex items-center justify-center rounded-[0.33em] bg-amber-100 text-amber-700 dark:text-amber-400 dark:bg-amber-950/40 dark:text-amber-300"
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
            ? 'mx-auto flex items-center justify-center w-9 h-9 rounded text-secondary hover:bg-hover/60 disabled:opacity-50 disabled:cursor-wait'
            : 'w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 text-secondary hover:bg-hover/60 disabled:opacity-50 disabled:cursor-wait'
          }
        >
          <PhArrowsClockwise
            width={collapsed ? 16 : 13} height={collapsed ? 16 : 13}
            class={`text-muted shrink-0 ${reindexing ? 'animate-spin' : ''}`}
          />
          {!collapsed && <span class="flex-1">{reindexing ? '索引中…' : '重建索引'}</span>}
        </button>
        <button
          onClick={onOpenTrash}
          title={collapsed ? '回收站' : '回收站'}
          class={rowCls(trashActive)}
        >
          <Icon name="trash" size={collapsed ? 16 : 13} class={trashActive ? 'text-white/80' : 'text-muted'} />
          {!collapsed && <span class="flex-1">回收站</span>}
        </button>
        <button
          onClick={onOpenSettings}
          title={collapsed ? '设置' : undefined}
          class={collapsed
            ? 'mx-auto flex items-center justify-center w-9 h-9 rounded text-secondary hover:bg-hover/60'
            : 'w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 text-secondary hover:bg-hover/60'
          }
        >
          <Icon name="gear" size={collapsed ? 16 : 13} class="text-muted" />
          {!collapsed && <span class="flex-1">设置</span>}
        </button>
      </div>
    </aside>
  );
}
