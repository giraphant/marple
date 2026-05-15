import type { Entry } from '../types';

interface Props {
  entry: Entry;
  onClick: (entry: Entry) => void;
}

export function MiniRow({ entry, onClick }: Props) {
  const fallback = entry.path.split('/').pop()!.replace(/\.md$/, '');
  return (
    <button
      onClick={() => onClick(entry)}
      class="block w-full text-left px-2 py-1 rounded hover:bg-surface-2 text-[12px] leading-snug"
    >
      <div class="flex items-center gap-1.5">
        {entry.rating && (
          <span class="text-amber-600 dark:text-amber-400 text-[10px] shrink-0">{entry.rating}</span>
        )}
        <span class="text-primary line-clamp-1">{entry.title || fallback}</span>
      </div>
      {entry.author && (
        <div class="text-[10px] text-muted line-clamp-1 pl-0">
          {entry.author}
          {entry.year ? ' · ' + entry.year : ''}
        </div>
      )}
    </button>
  );
}
