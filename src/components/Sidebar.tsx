import type { Entry, EntryType, TypeMeta } from '../types';
import { TYPES } from '../types';
import { TypeIcon } from './TypeIcon';
import { Icon } from './Icon';
import PhTag from '~icons/ph/tag';
import PhChartLineUp from '~icons/ph/chart-line-up';
import PhArrowsClockwise from '~icons/ph/arrows-clockwise';

interface Props {
  entries: Entry[];
  counts: Record<string, number>;
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
  onOpenTrash: () => void;
  onOpenThemes: () => void;
  onOpenActivity: () => void;
  onOpenSettings: () => void;
  onNewIdeaNote: () => void;
  onReindex: () => void;
}

export function Sidebar({
  counts, activeType, trashActive, themesActive, themesCount, activityActive, reindexing,
  onSelectType, onOpenTrash, onOpenThemes, onOpenActivity,
  onOpenSettings, onNewIdeaNote, onReindex,
}: Props) {
  return (
    <aside class="w-60 shrink-0 bg-page border-r border-base flex flex-col text-primary">
      <div class="px-4 py-3 border-b border-base">
        <div class="text-[13px] font-semibold tracking-tight text-primary">qua</div>
        <div class="text-[10px] text-muted uppercase tracking-wider mt-0.5">reader</div>
      </div>

      <div class="px-2 py-2 border-b border-base space-y-0.5">
        <button
          onClick={onNewIdeaNote}
          class="w-full text-left px-2 py-1.5 rounded text-[12px] hover:bg-hover/60 flex items-center gap-2 text-secondary"
          title="新建独立 idea note"
        >
          <Icon name="plus" size={13} class="text-muted" />
          <span>新建 note</span>
        </button>
      </div>

      <nav class="flex-1 overflow-auto scrollbar-thin px-2 py-3">
        <div class="text-[10px] uppercase tracking-wider text-muted font-semibold px-2 mb-1.5">Object types</div>
        {TYPES.map((t: TypeMeta) => {
          const active = t.id === activeType;
          const n = counts[t.id] ?? 0;
          return (
            <button
              key={t.id}
              onClick={() => onSelectType(t.id)}
              class={`w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 transition ${
                active
                  ? 'bg-inverse text-inverse-fg'
                  : 'text-secondary hover:bg-hover/60'
              }`}
            >
              <TypeIcon type={t.id} />
              <span class="flex-1 truncate">{t.label}</span>
              <span class={`text-[11px] tabular-nums ${active ? 'text-white/70' : 'text-muted'}`}>{n}</span>
            </button>
          );
        })}

        <div class="text-[10px] uppercase tracking-wider text-muted font-semibold px-2 mt-4 mb-1.5">横切视图</div>
        <button
          onClick={onOpenThemes}
          class={`w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 transition ${
            themesActive
              ? 'bg-inverse text-inverse-fg'
              : 'text-secondary hover:bg-hover/60'
          }`}
        >
          <span
            class={`shrink-0 inline-flex items-center justify-center rounded-[0.33em] bg-amber-100 text-amber-700 dark:text-amber-400 dark:bg-amber-950/40 dark:text-amber-300`}
            style={{ minHeight: '1.3em', minWidth: '1.3em', height: '1.3em', width: '1.3em' }}
            aria-hidden="true"
          >
            <PhTag width="0.94em" height="0.94em" style={{ padding: '0.05em' }} />
          </span>
          <span class="flex-1 truncate">主题</span>
          <span class={`text-[11px] tabular-nums ${themesActive ? 'text-white/70' : 'text-muted'}`}>{themesCount}</span>
        </button>
        <button
          onClick={onOpenActivity}
          class={`w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 transition ${
            activityActive
              ? 'bg-inverse text-inverse-fg'
              : 'text-secondary hover:bg-hover/60'
          }`}
        >
          <span
            class={`shrink-0 inline-flex items-center justify-center rounded-[0.33em] bg-amber-100 text-amber-700 dark:text-amber-400 dark:bg-amber-950/40 dark:text-amber-300`}
            style={{ minHeight: '1.3em', minWidth: '1.3em', height: '1.3em', width: '1.3em' }}
            aria-hidden="true"
          >
            <PhChartLineUp width="0.94em" height="0.94em" style={{ padding: '0.05em' }} />
          </span>
          <span class="flex-1 truncate">活动</span>
        </button>
      </nav>

      <div class="border-t border-base p-2 space-y-0.5">
        <button
          onClick={onReindex}
          disabled={reindexing}
          title="重新扫描 vault/ 生成索引（处理新 paper / author 后用）"
          class="w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 text-secondary hover:bg-hover/60 disabled:opacity-50 disabled:cursor-wait"
        >
          <PhArrowsClockwise
            width="13" height="13"
            class={`text-muted shrink-0 ${reindexing ? 'animate-spin' : ''}`}
          />
          <span class="flex-1">{reindexing ? '索引中…' : '重建索引'}</span>
        </button>
        <button
          onClick={onOpenTrash}
          title="回收站"
          class={`w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 transition ${
            trashActive
              ? 'bg-inverse text-inverse-fg'
              : 'text-secondary hover:bg-hover/60'
          }`}
        >
          <Icon name="trash" size={13} class={trashActive ? 'text-white/80' : 'text-muted'} />
          <span class="flex-1">回收站</span>
        </button>
        <button
          onClick={onOpenSettings}
          class="w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 text-secondary hover:bg-hover/60"
        >
          <Icon name="gear" size={13} class="text-muted" />
          <span class="flex-1">设置</span>
        </button>
      </div>
    </aside>
  );
}
