import type { Entry, EntryType, TypeMeta } from '../types';
import { TYPES } from '../types';
import { TypeIcon } from './TypeIcon';

interface Props {
  entries: Entry[];
  counts: Record<string, number>;
  /** Currently highlighted type — only set when the active tab is a ListTab. */
  activeType: EntryType | null;
  onSelectType: (id: EntryType) => void;
  onOpenSettings: () => void;
  onNewIdeaNote: () => void;
}

export function Sidebar({
  counts, activeType, onSelectType, onOpenSettings, onNewIdeaNote,
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
          class="w-full text-left px-2 py-1.5 rounded text-[12px] hover:bg-stone-200/60 flex items-center gap-2"
          title="新建独立 idea note"
        >
          <span class="text-stone-500 text-[13px] leading-none">＋</span>
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
      </nav>

      <div class="border-t border-stone-200 p-2 space-y-0.5">
        <button
          disabled
          title="回收站浏览（下一轮）"
          class="w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 text-stone-400 cursor-not-allowed"
        >
          <span class="text-[13px] leading-none w-4 text-center">🗑</span>
          <span class="flex-1">回收站</span>
        </button>
        <button
          onClick={onOpenSettings}
          class="w-full text-left px-2 py-1.5 rounded text-[12px] flex items-center gap-2 text-stone-700 hover:bg-stone-200/60"
        >
          <span class="text-[13px] leading-none w-4 text-center">⚙</span>
          <span class="flex-1">设置</span>
        </button>
      </div>
    </aside>
  );
}
