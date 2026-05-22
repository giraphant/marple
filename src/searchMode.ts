/** The three search modes, mirrored by `reader_core::SearchMode` on the server. */
export type SearchMode = 'fast' | 'balanced' | 'deep';

/** Display order, also the Tab-cycle order. */
export const SEARCH_MODES: SearchMode[] = ['fast', 'balanced', 'deep'];

/** Next mode in the Tab cycle (wraps deep → fast). */
export function nextSearchMode(mode: SearchMode): SearchMode {
  const i = SEARCH_MODES.indexOf(mode);
  return SEARCH_MODES[(i + 1) % SEARCH_MODES.length];
}

interface SearchModeMeta {
  /** Short chip/segment label. */
  label: string;
  /** Search input placeholder. */
  placeholder: string;
  /** In-flight status text shown while the request is pending. */
  loading: string;
}

/** A subtle relevance-source tag for a result row. Only the semantically
 *  distinctive sources (vector recall / vector+lexical fusion) get a badge —
 *  plain lexical matches (phrase/fulltext/expanded/fuzzy/substring) return null
 *  so Fast/Balanced rows stay clean and Deep visibly reveals what vectors added. */
export function sourceBadge(source: string | undefined): { label: string } | null {
  if (!source) return null;
  // Deep can suffix a marker (e.g. "fulltext (lex-fallback:no-vectors)"); match
  // on the leading token.
  const head = source.split(' ')[0];
  if (head === 'hybrid') return { label: '混合' };
  if (head === 'vec') return { label: '向量' };
  return null;
}

export const SEARCH_MODE_META: Record<SearchMode, SearchModeMeta> = {
  fast: {
    label: '快速',
    placeholder: '快速检索 标题/作者/主题…  Tab 切换 · ⏎ 打开 · Esc 关闭',
    loading: '元数据…',
  },
  balanced: {
    label: '平衡',
    placeholder: '平衡检索 标题/作者/主题/正文…  Tab 切换 · ⏎ 打开 · Esc 关闭',
    loading: '全文…',
  },
  deep: {
    label: '深度',
    placeholder: '深度检索 跨语言 / 概念 / 自然语言…  Tab 切换 · ⏎ 打开 · Esc 关闭',
    loading: '深度…（首次加载语义模型 ~2s）',
  },
};
