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
    accent: 'bg-surface-2 text-secondary border-base',
  };
  const themes = entry.themes ?? [];
  const fallbackTitle = entry.path.split('/').pop()!.replace(/\.md$/, '');
  return (
    <div
      class="card bg-surface border border-base rounded-md p-3 hover:border-strong hover:shadow-sm cursor-pointer flex flex-col gap-1.5 transition"
      onClick={(ev: MouseEvent) => onClick(entry, ev)}
    >
      <div class="flex items-center justify-between text-[11px]">
        <span class={`px-1.5 py-0.5 rounded border ${t.accent}`}>{t.label}</span>
        <span class="text-muted tabular-nums">
          {entry.rating || ''}
          {entry.rating && entry.year ? ' · ' : ''}
          {entry.year || ''}
        </span>
      </div>
      <div class="font-medium text-[13px] leading-snug line-clamp-3 text-primary">
        {entry.title || fallbackTitle}
      </div>
      {entry.author && (
        <div class="text-[11px] text-secondary line-clamp-2">{entry.author}</div>
      )}
      {entry.preview && (
        <div class="text-[11px] text-muted line-clamp-4 leading-relaxed">{entry.preview}</div>
      )}
      {themes.length > 0 && (
        <div class="flex flex-wrap gap-1 mt-auto pt-1.5 border-t border-base">
          {themes.slice(0, 3).map(th => (
            <span class="text-[10px] px-1.5 py-0.5 bg-page text-secondary rounded border border-base">{th}</span>
          ))}
          {themes.length > 3 && (
            <span class="text-[10px] text-muted self-center">+{themes.length - 3}</span>
          )}
        </div>
      )}
    </div>
  );
}
