import type { EntryType } from '../types';
import PhArticle from '~icons/ph/article';
import PhBook from '~icons/ph/book';
import PhBookmarks from '~icons/ph/bookmarks';
import PhUser from '~icons/ph/user';
import PhTarget from '~icons/ph/target';
import PhLightbulb from '~icons/ph/lightbulb';

/**
 * Capacities-style typed icon: a small rounded color square holding a
 * Phosphor regular SVG. Pale tint background + saturated foreground.
 * Backed by unplugin-icons (no hand-copied paths).
 */

interface Props {
  type: EntryType;
  /** Optional size scale; defaults to 1.3em square (Capacities default). */
  scale?: number;
}

const COMPONENT: Record<EntryType, typeof PhArticle> = {
  'paper-analysis':  PhArticle,
  'book-overview':   PhBook,
  'chapter-summary': PhBookmarks,
  'author-profile':  PhUser,
  'topic-synthesis': PhTarget,
  'note':            PhLightbulb,
};

// Light: bg-X-100 + text-X-700. Dark: muted X-950 wash + X-300 fg so the
// chips stay legible without glowing against the warm-dark canvas.
const COLORS: Record<EntryType, { bg: string; fg: string }> = {
  'paper-analysis':  { bg: 'bg-amber-100   dark:bg-amber-950/40',   fg: 'text-amber-700   dark:text-amber-300'   },
  'book-overview':   { bg: 'bg-emerald-100 dark:bg-emerald-950/40', fg: 'text-emerald-700 dark:text-emerald-300' },
  'chapter-summary': { bg: 'bg-teal-100    dark:bg-teal-950/40',    fg: 'text-teal-700    dark:text-teal-300'    },
  'author-profile':  { bg: 'bg-sky-100     dark:bg-sky-950/40',     fg: 'text-sky-700     dark:text-sky-300'     },
  'topic-synthesis': { bg: 'bg-violet-100  dark:bg-violet-950/40',  fg: 'text-violet-700  dark:text-violet-300'  },
  'note':            { bg: 'bg-rose-100    dark:bg-rose-950/40',    fg: 'text-rose-700    dark:text-rose-300'    },
};

export function TypeIcon({ type, scale = 1.3 }: Props) {
  const c = COLORS[type];
  const C = COMPONENT[type];
  const sizeEm = `${scale}em`;
  return (
    <span
      class={`shrink-0 inline-flex items-center justify-center rounded-[0.33em] ${c.bg} ${c.fg}`}
      style={{ minHeight: sizeEm, minWidth: sizeEm, height: sizeEm, width: sizeEm }}
      aria-hidden="true"
    >
      <C width="0.94em" height="0.94em" style={{ padding: '0.05em' }} />
    </span>
  );
}
