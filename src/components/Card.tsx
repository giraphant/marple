import type { Entry } from '../types';
import { TYPE_BY_ID } from '../types';

interface Props {
  entry: Entry;
  /** Receives the entry and the mouse event so callers can read modifier keys
   *  (e.g. Cmd/Ctrl to open in a new tab). */
  onClick: (entry: Entry, ev: MouseEvent) => void;
}

export function Card({ entry, onClick }: Props) {
  const t = TYPE_BY_ID[entry.type] ?? {
    label: entry.type,
    accent: 'bg-stone-100 text-stone-700 border-stone-200',
  };
  const themes = entry.themes ?? [];
  const fallbackTitle = entry.path.split('/').pop()!.replace(/\.md$/, '');
  return (
    <div
      class="card bg-white border border-stone-200 rounded-md p-3 hover:border-stone-400 hover:shadow-sm cursor-pointer flex flex-col gap-1.5 transition"
      onClick={(ev: MouseEvent) => onClick(entry, ev)}
    >
      <div class="flex items-center justify-between text-[11px]">
        <span class={`px-1.5 py-0.5 rounded border ${t.accent}`}>{t.label}</span>
        <span class="text-stone-500 tabular-nums">
          {entry.rating || ''}
          {entry.rating && entry.year ? ' · ' : ''}
          {entry.year || ''}
        </span>
      </div>
      <div class="font-medium text-[13px] leading-snug line-clamp-3 text-stone-900">
        {entry.title || fallbackTitle}
      </div>
      {entry.author && (
        <div class="text-[11px] text-stone-600 line-clamp-2">{entry.author}</div>
      )}
      {entry.preview && (
        <div class="text-[11px] text-stone-500 line-clamp-4 leading-relaxed">{entry.preview}</div>
      )}
      {themes.length > 0 && (
        <div class="flex flex-wrap gap-1 mt-auto pt-1.5 border-t border-stone-100">
          {themes.slice(0, 3).map(th => (
            <span class="text-[10px] px-1.5 py-0.5 bg-stone-50 text-stone-600 rounded border border-stone-100">{th}</span>
          ))}
          {themes.length > 3 && (
            <span class="text-[10px] text-stone-400 self-center">+{themes.length - 3}</span>
          )}
        </div>
      )}
    </div>
  );
}
