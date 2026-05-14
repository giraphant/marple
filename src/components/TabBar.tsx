import { useState } from 'preact/hooks';
import type { Entry, EntryType, Tab } from '../types';
import { TYPE_BY_ID, activeContent } from '../types';
import { TypeIcon } from './TypeIcon';
import { Icon } from './Icon';
import PhTag from '~icons/ph/tag';
import PhChartLineUp from '~icons/ph/chart-line-up';
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
  if (content.kind === 'trash') {
    return {
      icon: (
        <span
          class="shrink-0 inline-flex items-center justify-center rounded-[0.33em] bg-stone-200 text-stone-600"
          style={{ minWidth: '1.2em', minHeight: '1.2em', height: '1.2em', width: '1.2em' }}
        >
          <Icon name="trash" size={10} />
        </span>
      ),
      title: '回收站',
      type: null,
    };
  }
  if (content.kind === 'themes') {
    return {
      icon: (
        <span
          class="shrink-0 inline-flex items-center justify-center rounded-[0.33em] bg-amber-100 text-amber-700"
          style={{ minWidth: '1.2em', minHeight: '1.2em', height: '1.2em', width: '1.2em' }}
        >
          <PhTag width="0.85em" height="0.85em" />
        </span>
      ),
      title: '主题',
      type: null,
    };
  }
  if (content.kind === 'activity') {
    return {
      icon: (
        <span
          class="shrink-0 inline-flex items-center justify-center rounded-[0.33em] bg-amber-100 text-amber-700"
          style={{ minWidth: '1.2em', minHeight: '1.2em', height: '1.2em', width: '1.2em' }}
        >
          <PhChartLineUp width="0.85em" height="0.85em" />
        </span>
      ),
      title: '活动',
      type: null,
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
        title="后退 (Cmd+[)"
        class="shrink-0 w-7 h-7 inline-flex items-center justify-center rounded text-stone-500 hover:bg-stone-200/60 hover:text-stone-900 disabled:opacity-30 disabled:hover:bg-transparent"
      >
        <Icon name="caret-left" />
      </button>
      <button
        onClick={onForward}
        disabled={!canForward}
        title="前进 (Cmd+])"
        class="shrink-0 w-7 h-7 inline-flex items-center justify-center rounded text-stone-500 hover:bg-stone-200/60 hover:text-stone-900 disabled:opacity-30 disabled:hover:bg-transparent"
      >
        <Icon name="caret-right" />
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
          const tabK =
            cur.kind === 'list'     ? `list:${cur.type}:${i}` :
            cur.kind === 'doc'      ? `doc:${cur.path}:${i}`  :
            cur.kind === 'themes'   ? `themes:${i}`           :
            cur.kind === 'activity' ? `activity:${i}`         :
                                      `trash:${i}`;
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
                  class={`px-0.5 inline-flex items-center transition ${
                    pinned
                      ? 'text-amber-600 hover:text-amber-800'
                      : 'text-stone-400 hover:text-stone-700 opacity-0 group-hover:opacity-100'
                  }`}
                  title={pinned ? '取消固定' : '固定 tab'}
                >
                  <Icon name={pinned ? 'pin-fill' : 'pin'} size={11} />
                </button>
              )}
              {active && !pinned && !onlyOne && (
                <button
                  onClick={(ev) => { ev.stopPropagation(); onClose(i); }}
                  class="text-stone-400 hover:text-stone-900 px-0.5 inline-flex items-center"
                  title="关闭 tab"
                ><Icon name="x" size={12} /></button>
              )}
            </div>
          );
        })}
      </div>

      <button
        onClick={onNewTab}
        title="新建 tab"
        class="shrink-0 w-7 h-7 inline-flex items-center justify-center rounded text-stone-500 hover:bg-stone-200/60 hover:text-stone-900"
      ><Icon name="plus" /></button>
    </div>
  );
}
