import type { Entry } from '../types';

interface Props {
  entry: Entry;
  /** Receives the entry and the mouse event so callers can read modifier keys
   *  (e.g. Cmd/Ctrl to open in a new tab). */
  onClick: (entry: Entry, ev: MouseEvent) => void;
  /** Click a theme chip to filter by it (stops the card's open-on-click). */
  onThemeClick?: (theme: string) => void;
}

export function Card({ entry, onClick, onThemeClick }: Props) {
  const themes = entry.themes ?? [];
  const fallbackTitle = entry.path.split('/').pop()!.replace(/\.md$/, '');
  // Cards only ever render inside a single-type list, so the type badge would be
  // identical on every card — dropped for scannability. Title leads; author·year
  // collapse into one muted meta line; the preview is demoted under both.
  return (
    <div
      class="card bg-surface border border-base rounded-2xl p-4 shadow-soft hover:shadow-soft-lg hover:-translate-y-0.5 active:translate-y-0 active:shadow-soft cursor-pointer flex flex-col gap-2 transition"
      onClick={(ev: MouseEvent) => onClick(entry, ev)}
    >
      <div class="flex items-start justify-between gap-2.5">
        <div class="font-semibold text-[15px] leading-snug line-clamp-2 text-primary tracking-[-0.01em]">
          {entry.title || fallbackTitle}
        </div>
        {entry.rating && (
          <span class="shrink-0 mt-0.5 text-[12px] text-star tabular-nums">{entry.rating}</span>
        )}
      </div>

      {(entry.author || entry.year) && (
        <div class="text-[11.5px] text-muted line-clamp-1">
          {entry.author}
          {entry.author && entry.year ? <span> · </span> : null}
          {entry.year && <span class="tabular-nums">{entry.year}</span>}
        </div>
      )}

      {entry.preview && (
        <div class="text-[12px] text-muted line-clamp-2 leading-relaxed">{entry.preview}</div>
      )}

      {themes.length > 0 && (
        <div class="flex flex-wrap gap-1.5 mt-auto pt-2.5 border-t border-base">
          {themes.slice(0, 3).map(th => (
            <button
              key={th}
              onClick={(ev: MouseEvent) => { ev.stopPropagation(); onThemeClick?.(th); }}
              class="text-[10.5px] px-2 py-0.5 bg-page text-secondary rounded-md hover:bg-accent-bg hover:text-accent-text transition"
              title={`按主题筛选：${th}`}
            >{th}</button>
          ))}
          {themes.length > 3 && (
            <span class="text-[10.5px] text-muted self-center">+{themes.length - 3}</span>
          )}
        </div>
      )}
    </div>
  );
}
