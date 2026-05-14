import { useState } from 'preact/hooks';
import type { Entry, EntryType, Tab } from '../types';
import { TYPE_BY_ID, activeContent } from '../types';
import { TypeIcon } from './TypeIcon';
import type { JSX } from 'preact';

interface Props {
  tabs: Tab[];
  activeIndex: number;
  entryByPath: Map<string, Entry>;
  onActivate: (index: number) => void;
  onClose: (index: number) => void;
  onNewTab: () => void;
  onTogglePin: (index: number) => void;
  onReorder: (from: number, to: number) => void;
  onBack?: () => void;
  onForward?: () => void;
  canBack?: boolean;
  canForward?: boolean;
}

function PinIcon({ filled }: { filled: boolean }) {
  // Phosphor "Push Pin" outline vs fill.
  return (
    <svg viewBox="0 0 256 256" fill="currentColor" width="11" height="11" aria-hidden="true">
      {filled ? (
        <path d="M236 100c0-9.41-4.46-18.21-12.24-24.16L171.9 35.42a32 32 0 0 0-44.86 5.83c-6.84 9-9.06 19.95-6 30.07L72.86 110l-9.7-7.55a16 16 0 0 0-22.49 22.49l25.91 33.26L20 224a8 8 0 0 0 11.31 11.31l64.83-46.59L129.4 215a16 16 0 0 0 22.49-22.49l-7.55-9.7 38.69-48.18c10.11 3.04 21 .82 30.06-6a30.07 30.07 0 0 0 12.21-23.79z" />
      ) : (
        <path d="M235.5 81.45 174.55 20.5a17.85 17.85 0 0 0-25.27 0L122.07 47.7a31.85 31.85 0 0 0-8.41 30.43L82.27 109.5l-12.61-8.82a17.85 17.85 0 0 0-22.66 2.13l-3.78 3.78a17.85 17.85 0 0 0 0 25.27l34 34L34 244.34a8 8 0 0 0 11.31 11.31l45.27-45.27 34 34a17.85 17.85 0 0 0 25.27 0l3.78-3.78a17.85 17.85 0 0 0 2.13-22.66l-8.82-12.61 31.37-31.39a31.85 31.85 0 0 0 30.43-8.41l27.2-27.2a17.85 17.85 0 0 0 0-25.28zm-87.34 78.62a8 8 0 0 0-1.39 9.55l11.92 17a1.85 1.85 0 0 1-.22 2.35l-3.78 3.78a1.85 1.85 0 0 1-2.61 0L65.66 117a1.85 1.85 0 0 1 0-2.61l3.78-3.78a1.85 1.85 0 0 1 2.35-.22l17 11.92a8 8 0 0 0 9.55-1.39l37.13-37.13a8 8 0 0 0 2-7.82A15.86 15.86 0 0 1 141 60.74l30.69-30.69 54.27 54.27-30.69 30.69a15.86 15.86 0 0 1-15.23 4.15 8 8 0 0 0-7.82 2.06z" />
      )}
    </svg>
  );
}

function tabDisplay(tab: Tab, entryByPath: Map<string, Entry>): {
  icon: JSX.Element;
  title: string;
  type: EntryType | null;
} {
  const content = activeContent(tab);
  if (content.kind === 'list') {
    const meta = TYPE_BY_ID[content.type];
    return {
      icon: <TypeIcon type={content.type} scale={1.2} />,
      title: meta?.label ?? content.type,
      type: content.type,
    };
  }
  const entry = entryByPath.get(content.path);
  if (entry) {
    return {
      icon: <TypeIcon type={entry.type} scale={1.2} />,
      title: entry.title || entry.path.split('/').pop()!.replace(/\.md$/, ''),
      type: entry.type,
    };
  }
  return {
    icon: <span class="text-stone-400 text-[14px] leading-none">⚠</span>,
    title: content.path.split('/').pop()!.replace(/\.md$/, ''),
    type: null,
  };
}

export function TabBar({
  tabs, activeIndex, entryByPath, onActivate, onClose, onNewTab, onTogglePin, onReorder,
  onBack, onForward, canBack, canForward,
}: Props) {
  const onlyOne = tabs.length <= 1;
  const [dragFrom, setDragFrom] = useState<number | null>(null);
  // dropTo encodes the *insertion slot* — 0 means "before tab 0", tabs.length
  // means "after the last tab". Slot N means "before tab N (after tab N-1)".
  const [dropSlot, setDropSlot] = useState<number | null>(null);
  return (
    <div class="bg-stone-50 border-b border-stone-200 flex items-center gap-1 px-2 py-1.5 overflow-x-auto scrollbar-thin">
      <button
        onClick={onBack}
        disabled={!canBack}
        title="后退"
        class="shrink-0 w-7 h-7 inline-flex items-center justify-center rounded text-stone-500 hover:bg-stone-200/60 hover:text-stone-900 disabled:opacity-30 disabled:hover:bg-transparent"
      >
        <svg viewBox="0 0 256 256" fill="currentColor" width="14" height="14" aria-hidden="true">
          <path d="M165.66 202.34a8 8 0 0 1-11.32 11.32l-80-80a8 8 0 0 1 0-11.32l80-80a8 8 0 0 1 11.32 11.32L91.31 128Z" />
        </svg>
      </button>
      <button
        onClick={onForward}
        disabled={!canForward}
        title="前进"
        class="shrink-0 w-7 h-7 inline-flex items-center justify-center rounded text-stone-500 hover:bg-stone-200/60 hover:text-stone-900 disabled:opacity-30 disabled:hover:bg-transparent"
      >
        <svg viewBox="0 0 256 256" fill="currentColor" width="14" height="14" aria-hidden="true">
          <path d="M181.66 133.66l-80 80a8 8 0 0 1-11.32-11.32L164.69 128 90.34 53.66a8 8 0 0 1 11.32-11.32l80 80a8 8 0 0 1 0 11.32Z" />
        </svg>
      </button>

      <div class="flex items-center gap-1 min-w-0">
        {tabs.map((tab, i) => {
          const { icon, title } = tabDisplay(tab, entryByPath);
          const active = i === activeIndex;
          const pinned = !!tab.pinned;
          const isDragging = dragFrom === i;
          // Insertion indicator: show on the leading edge if dropSlot === i,
          // and on the trailing edge of the last tab if dropSlot === tabs.length.
          const showLeftIndicator = dropSlot === i && dragFrom !== null && dragFrom !== i && dragFrom !== i - 1;
          const showRightIndicator = dropSlot === i + 1 && i === tabs.length - 1 && dragFrom !== null && dragFrom !== i;
          const cur = activeContent(tab);
          const tabK = cur.kind === 'list' ? `list:${cur.type}:${i}` : `doc:${cur.path}:${i}`;
          return (
            <div
              key={tabK}
              draggable
              onDragStart={(ev) => {
                setDragFrom(i);
                if (ev.dataTransfer) {
                  ev.dataTransfer.effectAllowed = 'move';
                  // Setting any data makes Firefox actually start the drag.
                  ev.dataTransfer.setData('text/plain', String(i));
                }
              }}
              onDragOver={(ev) => {
                if (dragFrom === null) return;
                // pinned tabs may only be reordered among themselves and vice versa
                if (tabs[dragFrom].pinned !== pinned) return;
                ev.preventDefault();
                const rect = (ev.currentTarget as HTMLElement).getBoundingClientRect();
                const before = ev.clientX < rect.left + rect.width / 2;
                setDropSlot(before ? i : i + 1);
              }}
              onDragLeave={() => {
                // No-op: dragOver on a sibling will overwrite dropSlot anyway.
              }}
              onDrop={(ev) => {
                ev.preventDefault();
                const from = dragFrom;
                const to = dropSlot;
                setDragFrom(null);
                setDropSlot(null);
                if (from == null || to == null) return;
                // Translate insertion slot to a target index after removal.
                const adjusted = to > from ? to - 1 : to;
                if (adjusted === from) return;
                onReorder(from, adjusted);
              }}
              onDragEnd={() => { setDragFrom(null); setDropSlot(null); }}
              class={`group relative flex items-center gap-1.5 py-1 text-[12px] rounded-md border cursor-pointer select-none min-w-0 transition ${
                pinned ? 'pl-2.5 pr-1.5 max-w-[180px]' : 'pl-2.5 pr-1.5 max-w-[220px]'
              } ${
                active
                  ? 'bg-white border-stone-300 text-stone-900 shadow-sm'
                  : 'bg-transparent border-transparent text-stone-500 hover:bg-stone-200/60 hover:text-stone-700'
              } ${isDragging ? 'opacity-40' : ''}`}
              style={{
                boxShadow: showLeftIndicator
                  ? 'inset 2px 0 0 0 #0c0a09'
                  : showRightIndicator
                    ? 'inset -2px 0 0 0 #0c0a09'
                    : undefined,
              }}
              onClick={() => onActivate(i)}
              title={pinned ? `📌 ${title}` : title}
              onAuxClick={(ev) => {
                if (ev.button === 1 && !pinned && !onlyOne) {
                  ev.preventDefault();
                  onClose(i);
                }
              }}
            >
              {icon}
              <span class="truncate flex-1 min-w-0">{title}</span>
              {active && (
                <button
                  onClick={(ev) => { ev.stopPropagation(); onTogglePin(i); }}
                  class={`px-0.5 leading-none text-[12px] transition ${
                    pinned
                      ? 'text-amber-600 hover:text-amber-800'
                      : 'text-stone-400 hover:text-stone-700 opacity-0 group-hover:opacity-100'
                  }`}
                  title={pinned ? '取消固定' : '固定 tab'}
                >
                  <PinIcon filled={pinned} />
                </button>
              )}
              {active && !pinned && !onlyOne && (
                <button
                  onClick={(ev) => { ev.stopPropagation(); onClose(i); }}
                  class="text-stone-400 hover:text-stone-900 px-0.5 leading-none text-[14px]"
                  title="关闭 tab"
                >×</button>
              )}
            </div>
          );
        })}
      </div>

      <button
        onClick={onNewTab}
        title="新建 tab"
        class="shrink-0 w-7 h-7 inline-flex items-center justify-center rounded text-stone-500 hover:bg-stone-200/60 hover:text-stone-900 text-[16px] leading-none"
      >+</button>
    </div>
  );
}
