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
  author: string | null;
  year: number | string | null;
  rating: string | number | null;
  rating_score: number;
  themes: string[] | null;
  topic: string | null;
  source: string | null;
  doi: string | null;
  chapters_analyzed: number | null;
  /** For notes: vault-relative path of the file this note annotates. */
  annotates: string | null;
  /** For notes: ISO date in frontmatter. */
  created: string | null;
  preview: string;
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
  { id: 'paper-analysis',  label: '论文', accent: 'bg-amber-100  text-amber-800  border-amber-200'  },
  { id: 'book-overview',   label: '书',   accent: 'bg-emerald-100 text-emerald-800 border-emerald-200' },
  { id: 'author-profile',  label: '作者', accent: 'bg-sky-100    text-sky-800    border-sky-200'    },
  { id: 'topic-synthesis', label: '主题', accent: 'bg-violet-100 text-violet-800 border-violet-200' },
  { id: 'chapter-summary', label: '章节', accent: 'bg-teal-100   text-teal-800   border-teal-200'   },
  { id: 'note',            label: '笔记', accent: 'bg-rose-100   text-rose-800   border-rose-200'   },
];

export const TYPE_BY_ID: Record<string, TypeMeta> = Object.fromEntries(
  TYPES.map(t => [t.id, t])
);

/** What a tab is currently showing. Tabs hold a history of these. */
export type TabContent =
  | { kind: 'list'; type: EntryType }
  | { kind: 'doc'; path: string }
  | { kind: 'trash' };

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
  return 'trash';
}

