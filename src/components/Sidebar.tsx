import type { Entry, EntryType, TypeMeta } from '../types';
import { TYPES } from '../types';
import { TypeIcon } from './TypeIcon';
import { Icon } from './Icon';
import PhTag from '~icons/ph/tag';

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
  onSelectType: (id: EntryType) => void;
  onOpenTrash: () => void;
  onOpenThemes: () => void;
  onOpenSettings: () => void;
  onNewIdeaNote: () => void;
}

export function Sidebar({
  counts, activeType, trashActive, themesActive, themesCount,
  onSelectType, onOpenTrash, onOpenThemes, onOpenSettings, onNewIdeaNote,
}: Props) {
  return (
    <aside class="w-60 shrink-0 bg-stone-50 border-r border-stone-200 flex flex-col text-stone-800">
      <div class="px-4 py-3 border-b border-stone-200">
        <div class="text-[13px] font-semibold tracking-tight text-stone-900">qua</div>
        <div class="text-[10px] text-stone-500 uppercase tracking-wider mt-0.5">reader</div>
      </div>

      <div class="px-2 py-2 border-b border-stone-200 space-y-0.5">
        <button
          onClick={onNewIdeaNote}
          class="w-full text-left px-2 py-1.5 rounded text-[12px] hover:bg-stone-200/60 flex items-center gap-2 text-stone-700"
          title="新建独立 idea note"
        >
          <Icon name="plus" size={13} class="text-stone-500" />
          <span>新建 note</span>
        </button>
      </div>

      <nav class="flex-1 overflow-auto scrollbar-thin px-2 py-3">
        <div class="text-[10px] uppercase tracking-wider text-stone-500 font-semibold px-2 mb-1.5">Object types</div>
        {TYPES.map((t: TypeMeta) => {
          const active = t.id === activeType;
          const n = counts[t.id] ?? 0;
          return (
            <button
              key={t.id}
              onClick={() => onSelectType(t.id)}
              class={`w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 transition ${
                active
                  ? 'bg-stone-900 text-white'
                  : 'text-stone-700 hover:bg-stone-200/60'
              }`}
            >
              <TypeIcon type={t.id} />
              <span class="flex-1 truncate">{t.label}</span>
              <span class={`text-[11px] tabular-nums ${active ? 'text-white/70' : 'text-stone-400'}`}>{n}</span>
            </button>
          );
        })}

        <div class="text-[10px] uppercase tracking-wider text-stone-500 font-semibold px-2 mt-4 mb-1.5">横切视图</div>
        <button
          onClick={onOpenThemes}
          class={`w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 transition ${
            themesActive
              ? 'bg-stone-900 text-white'
              : 'text-stone-700 hover:bg-stone-200/60'
          }`}
        >
          <span
            class={`shrink-0 inline-flex items-center justify-center rounded-[0.33em] bg-amber-100 text-amber-700`}
            style={{ minHeight: '1.3em', minWidth: '1.3em', height: '1.3em', width: '1.3em' }}
            aria-hidden="true"
          >
            <PhTag width="0.94em" height="0.94em" style={{ padding: '0.05em' }} />
          </span>
          <span class="flex-1 truncate">主题</span>
          <span class={`text-[11px] tabular-nums ${themesActive ? 'text-white/70' : 'text-stone-400'}`}>{themesCount}</span>
        </button>
      </nav>

      <div class="border-t border-stone-200 p-2 space-y-0.5">
        <button
          onClick={onOpenTrash}
          title="回收站"
          class={`w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 transition ${
            trashActive
              ? 'bg-stone-900 text-white'
              : 'text-stone-700 hover:bg-stone-200/60'
          }`}
        >
          <Icon name="trash" size={13} class={trashActive ? 'text-white/80' : 'text-stone-500'} />
          <span class="flex-1">回收站</span>
        </button>
        <button
          onClick={onOpenSettings}
          class="w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 text-stone-700 hover:bg-stone-200/60"
        >
          <Icon name="gear" size={13} class="text-stone-500" />
          <span class="flex-1">设置</span>
        </button>
      </div>
    </aside>
  );
}
