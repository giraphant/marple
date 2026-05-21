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
      class="card bg-surface border border-base rounded-2xl p-4 shadow-soft hover:shadow-soft-lg hover:-translate-y-px cursor-pointer flex flex-col gap-2.5 transition"
      onClick={(ev: MouseEvent) => onClick(entry, ev)}
    >
      <div class="flex items-center justify-between gap-2">
        <span class={`px-2 py-0.5 rounded-lg text-[11px] font-medium ${t.accent}`}>{t.label}</span>
        <span class="text-[11px] tabular-nums shrink-0">
          {entry.rating && <span class="text-star">{entry.rating}</span>}
          {entry.rating && entry.year ? <span class="text-muted"> · </span> : null}
          {entry.year && <span class="text-muted">{entry.year}</span>}
        </span>
      </div>
      <div class="font-semibold text-[14px] leading-snug line-clamp-3 text-primary tracking-[-0.01em]">
        {entry.title || fallbackTitle}
      </div>
      {entry.author && (
        <div class="text-[11.5px] text-muted line-clamp-1">{entry.author}</div>
      )}
      {entry.preview && (
        <div class="text-[12.5px] text-muted line-clamp-3 leading-relaxed">{entry.preview}</div>
      )}
      {themes.length > 0 && (
        <div class="flex flex-wrap gap-1.5 mt-auto pt-2.5 border-t border-base">
          {themes.slice(0, 3).map(th => (
            <span class="text-[10.5px] px-2 py-0.5 bg-page text-secondary rounded-md">{th}</span>
          ))}
          {themes.length > 3 && (
            <span class="text-[10.5px] text-muted self-center">+{themes.length - 3}</span>
          )}
        </div>
      )}
    </div>
  );
}
