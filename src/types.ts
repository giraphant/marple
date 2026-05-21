export type EntryType =
  | 'paper-analysis'
  | 'book-overview'
  | 'chapter-summary'
  | 'author-profile'
  | 'topic-synthesis'
  | 'note';

export interface Entry {
  path: string;
  type: EntryType;
  book: string | null;
  title: string | null;
  title_en?: string | null;
  title_cn?: string | null;
  author: string | null;
  year: number | string | null;
  rating: string | number | null;
  rating_score: number;
  themes: string[] | null;
  topic: string | null;
  source: string | null;
  doi: string | null;
  publisher?: string | null;
  isbn?: string | null;
  chapters_analyzed: number | null;
  /** For notes: vault-relative path of the file this note annotates. */
  annotates: string | null;
  /** For notes: ISO date in frontmatter. */
  created: string | null;
  /** True when sources/<pdf_slug>.pdf exists for this entry. Filled by build-index. */
  has_pdf?: boolean;
  /** Filename stem under sources/ (paper basename, or book directory slug). */
  pdf_slug?: string | null;
  /** File mtime in epoch ms. Used for the activity heatmap. */
  mtime?: number | null;
  preview: string;
  /** Character count of the analysis body — drives the card's proportional
   *  preview length (longer analysis → more preview shown). */
  body_len?: number;
  /** Epoch-ms of the file's first git commit (true ingestion date), 0 if unknown. */
  added?: number;
}

export type EditableField =
  | 'rating'
  | 'year'
  | 'author'
  | 'source'
  | 'topic'
  | 'doi'
  | 'themes'
  | 'title';

export interface TypeMeta {
  id: EntryType;
  label: string;
  accent: string;
}

export const TYPES: TypeMeta[] = [
  { id: 'paper-analysis',  label: '论文', accent: 'bg-type-paper-bg   text-type-paper-fg   border-type-paper-fg/25'   },
  { id: 'book-overview',   label: '图书', accent: 'bg-type-book-bg    text-type-book-fg    border-type-book-fg/25'    },
  { id: 'author-profile',  label: '作者', accent: 'bg-type-author-bg  text-type-author-fg  border-type-author-fg/25'  },
  { id: 'topic-synthesis', label: '主题', accent: 'bg-type-topic-bg   text-type-topic-fg   border-type-topic-fg/25'   },
  { id: 'chapter-summary', label: '章节', accent: 'bg-type-chapter-bg text-type-chapter-fg border-type-chapter-fg/25' },
  { id: 'note',            label: '笔记', accent: 'bg-type-note-bg    text-type-note-fg    border-type-note-fg/25'    },
];

export const TYPE_BY_ID: Record<string, TypeMeta> = Object.fromEntries(
  TYPES.map(t => [t.id, t])
);

/** What a tab is currently showing. Tabs hold a history of these. */
export type TabContent =
  | { kind: 'list'; type: EntryType }
  | { kind: 'doc'; path: string }
  | { kind: 'trash' }
  | { kind: 'themes' }
  | { kind: 'activity' };

/** A tab in the top tab bar. Holds a back/forward history of TabContent
 *  plus a cursor pointing at the current entry. */
export interface Tab {
  history: TabContent[];
  cursor: number;
  pinned?: boolean;
}

export function activeContent(tab: Tab): TabContent {
  return tab.history[tab.cursor];
}

export function tabKey(tab: Tab): string {
  const c = activeContent(tab);
  if (c.kind === 'list') return `list:${c.type}`;
  if (c.kind === 'doc') return `doc:${c.path}`;
  return c.kind; // 'trash' | 'themes' | 'activity'
}

