import type { EntryType } from '../types';

/**
 * Capacities-style typed icon: a small rounded color square holding a
 * Phosphor-flavored SVG. Pale tint background + saturated foreground.
 * Sized in em so the icon scales with its parent's font-size.
 */

interface Props {
  type: EntryType;
  /** Optional size scale; defaults to 1.3em square (Capacities default). */
  scale?: number;
}

// Phosphor-style monoline paths normalized to viewBox 0 0 256 256.
// `fill="currentColor"` lets the foreground class drive the color.
const PATHS: Record<EntryType, string> = {
  // Lightbulb — Capacities uses this for "Ideas"; we reuse it for notes
  // (they are the closest equivalent in the qua vault).
  'note':
    'M176 232a8 8 0 0 1-8 8H88a8 8 0 0 1 0-16h80a8 8 0 0 1 8 8Zm40-128a87.55 87.55 0 0 1-33.64 69.21A16.24 16.24 0 0 0 176 186v6a16 16 0 0 1-16 16H96a16 16 0 0 1-16-16v-6a16 16 0 0 0-6.23-12.66A87.59 87.59 0 0 1 40 104.49C39.74 56.83 78.26 17.14 125.88 16A88 88 0 0 1 216 104Zm-16 0a72 72 0 0 0-73.74-72c-39 .92-70.47 33.39-70.26 72.39a71.65 71.65 0 0 0 27.64 56.3A32 32 0 0 1 96 186v6h64v-6a32.15 32.15 0 0 1 12.47-25.35A71.65 71.65 0 0 0 200 104Z',
  // Article — paper-analysis
  'paper-analysis':
    'M216 40H40a16 16 0 0 0-16 16v144a16 16 0 0 0 16 16h176a16 16 0 0 0 16-16V56a16 16 0 0 0-16-16Zm0 160H40V56h176v144Zm-16-100a8 8 0 0 1-8 8H64a8 8 0 0 1 0-16h128a8 8 0 0 1 8 8Zm0 32a8 8 0 0 1-8 8H64a8 8 0 0 1 0-16h128a8 8 0 0 1 8 8Zm-40 32a8 8 0 0 1-8 8H64a8 8 0 0 1 0-16h88a8 8 0 0 1 8 8Z',
  // Book — book-overview
  'book-overview':
    'M208 24H72A32 32 0 0 0 40 56v168a8 8 0 0 0 8 8h144a8 8 0 0 0 0-16H56a16 16 0 0 1 16-16h136a8 8 0 0 0 8-8V32a8 8 0 0 0-8-8Zm-8 160H72a32 32 0 0 0-16 4.29V56a16 16 0 0 1 16-16h128Z',
  // Bookmarks — chapter-summary (multi-page)
  'chapter-summary':
    'M192 24H80a16 16 0 0 0-16 16v8H48a16 16 0 0 0-16 16v152a8 8 0 0 0 12.45 6.65L80 198.43l35.55 24.22a8 8 0 0 0 9 0L160 198.43l35.55 24.22A8 8 0 0 0 208 216V64a16 16 0 0 0-16-16Zm-72 158.45-31.55-21.49a8 8 0 0 0-9 0L48 200.85V64h128v136.85l-31.45-21.4a8 8 0 0 0-9 0Zm72 18.4-16-10.9V64a16 16 0 0 0-16-16H80V40h112Z',
  // User — author-profile
  'author-profile':
    'M230.92 212c-15.23-26.33-38.7-45.21-66.09-54.16a72 72 0 1 0-73.66 0c-27.39 8.94-50.86 27.82-66.09 54.16a8 8 0 1 0 13.85 8c18.84-32.56 52.14-52 89.07-52s70.23 19.44 89.07 52a8 8 0 1 0 13.85-8ZM72 96a56 56 0 1 1 56 56 56.06 56.06 0 0 1-56-56Z',
  // Target — topic-synthesis
  'topic-synthesis':
    'M128 80a48 48 0 1 0 48 48 48.05 48.05 0 0 0-48-48Zm0 80a32 32 0 1 1 32-32 32 32 0 0 1-32 32Zm0-144a112 112 0 1 0 112 112A112.12 112.12 0 0 0 128 16Zm0 208a96 96 0 1 1 96-96 96.11 96.11 0 0 1-96 96Z',
};

// Pale tint background + saturated foreground per type. Mirrors the
// app-wide accent colors in types.ts but specialized for icon chips.
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
  const d = PATHS[type];
  const sizeEm = `${scale}em`;
  return (
    <span
      class={`shrink-0 inline-flex items-center justify-center rounded-[0.33em] ${c.bg} ${c.fg}`}
      style={{ minHeight: sizeEm, minWidth: sizeEm, height: sizeEm, width: sizeEm }}
      aria-hidden="true"
    >
      <svg
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 256 256"
        fill="currentColor"
        width="0.94em"
        height="0.94em"
        style={{ padding: '0.05em' }}
      >
        <path d={d} />
      </svg>
    </span>
  );
}
