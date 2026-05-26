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

// Each entry type maps to its design-token pair; dark values are baked into the tokens.
const COLORS: Record<EntryType, { bg: string; fg: string }> = {
  'paper-analysis':  { bg: 'bg-type-paper-bg',   fg: 'text-type-paper-fg'   },
  'book-overview':   { bg: 'bg-type-book-bg',    fg: 'text-type-book-fg'    },
  'chapter-summary': { bg: 'bg-type-chapter-bg', fg: 'text-type-chapter-fg' },
  'author-profile':  { bg: 'bg-type-author-bg',  fg: 'text-type-author-fg'  },
  'topic-synthesis': { bg: 'bg-type-topic-bg',   fg: 'text-type-topic-fg'   },
  'note':            { bg: 'bg-type-note-bg',    fg: 'text-type-note-fg'    },
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
