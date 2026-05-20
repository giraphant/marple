/** Embedding-job status as returned by GET /api/embeddings/status. */
export interface EmbedStatus {
  phase: 'idle' | 'running' | 'done' | 'failed';
  embedded: number;
  total: number;
  vectorsExist: boolean;
  vectorsCount: number | null;
  model: string | null;
  completedAt: string | null;
  startedAt: string | null;
  error: string | null;
}

export type EmbedTone = 'idle' | 'running' | 'done' | 'error';

export interface EmbedDisplay {
  label: string;
  tone: EmbedTone;
}

export function isEmbedRunning(s: EmbedStatus): boolean {
  return s.phase === 'running';
}

/** Pure mapping from raw status → a human label + tone for the Settings panel.
 *  Kept separate from the component so it can be unit-tested. */
export function formatEmbedStatus(s: EmbedStatus): EmbedDisplay {
  switch (s.phase) {
    case 'running':
      return {
        tone: 'running',
        label: s.total > 0
          ? `构建中… ${s.embedded} / ${s.total}`
          : '构建中…（加载模型 / 准备中）',
      };
    case 'failed':
      return { tone: 'error', label: `失败：${s.error ?? '未知错误'}` };
    case 'done':
      if ((s.vectorsCount ?? 0) > 0) {
        return { tone: 'done', label: `已构建 ${s.vectorsCount} 条语义向量` };
      }
      return { tone: 'done', label: '已完成（无可嵌入条目）' };
    case 'idle':
    default:
      if (s.vectorsExist) {
        return { tone: 'done', label: `已构建 ${s.vectorsCount ?? 0} 条语义向量` };
      }
      return { tone: 'idle', label: '未构建（语义 / hybrid 搜索暂不可用）' };
  }
}
