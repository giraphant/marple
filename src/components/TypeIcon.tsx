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

const COLORS: Record<EntryType, { bg: string; fg: string }> = {
  'paper-analysis':  { bg: 'bg-amber-100',   fg: 'text-amber-700'   },
  'book-overview':   { bg: 'bg-emerald-100', fg: 'text-emerald-700' },
  'chapter-summary': { bg: 'bg-teal-100',    fg: 'text-teal-700'    },
  'author-profile':  { bg: 'bg-sky-100',     fg: 'text-sky-700'     },
  'topic-synthesis': { bg: 'bg-violet-100',  fg: 'text-violet-700'  },
  'note':            { bg: 'bg-rose-100',    fg: 'text-rose-700'    },
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
