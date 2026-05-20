import { useMemo } from 'preact/hooks';
import type { JSX } from 'preact';
import { marked } from 'marked';
import type { Entry } from '../types';
import { resolveWikilinks } from '../wiki';
import { parseMarkdownTable } from './sections';

/**
 * Concept-table renderer.
 *
 * Used for `## 关键概念` / `## 关键概念表` / `## 核心概念谱系` H2 sections.
 * The SPEC says these are markdown tables with one row per concept. Common
 * column layouts in the vault:
 *
 *   book / chapter:
 *     概念 | 英文 | 提出者 | 出现章节 | 定义
 *
 *   author:
 *     概念 | 来源作品 | 演化轨迹 | 当前状态
 *
 * The component figures out each column's *role* by header name and styles
 * accordingly. Falls back to a vanilla table when the structure looks off.
 */

type ColumnRole =
  | 'name'         // 概念    — primary, bold
  | 'translation'  // 英文    — muted small
  | 'coiner'       // 提出者  — chip (wraps when long)
  | 'refs'         // 出现章节 — split into chips
  | 'definition'   // 定义    — prose, widest column
  | 'works'        // 来源作品 — wikilinks preserved
  | 'evolution'    // 演化轨迹 — prose
  | 'status'       // 当前状态 — chip
  | 'unknown';

interface Props {
  content: string;
  wikiIndex: Map<string, Entry>;
  onWikiClick: (path: string, modifiers: { meta: boolean }) => void;
}

/** Map a header cell to a role. Uses exact SPEC column names — the data
 *  pipeline is canonicalising to these, so we don't need fuzzy aliases. */
function classifyHeader(h: string): ColumnRole {
  switch (h.trim()) {
    case '概念':     return 'name';
    case '英文':     return 'translation';
    case '提出者':   return 'coiner';
    case '出现章节': return 'refs';
    case '定义':     return 'definition';
    case '来源作品': return 'works';
    case '演化轨迹': return 'evolution';
    case '当前状态': return 'status';
    default:         return 'unknown';
  }
}

/** Render inline markdown (italic, wikilinks already resolved to HTML) for a
 *  single cell. Returns trusted HTML — the only HTML we splice in is what
 *  resolveWikilinks emits + what marked emits from trusted markdown source. */
function renderCellInline(raw: string, wikiIndex: Map<string, Entry>): string {
  if (!raw) return '';
  const wiki = resolveWikilinks(raw, wikiIndex);
  // marked.parseInline returns string in sync mode (default).
  return marked.parseInline(wiki) as string;
}

/** Split a refs cell ("ch04, ch05, 导论") into trimmed tokens. Handles
 *  Chinese commas and ideographic enumeration mark (、) as well. */
function splitRefs(raw: string): string[] {
  return raw
    .split(/[,，、;；]/)
    .map(s => s.trim())
    .filter(Boolean);
}

export function ConceptTable({ content, wikiIndex, onWikiClick }: Props) {
  const parsed = useMemo(() => parseMarkdownTable(content), [content]);
  const roles = useMemo(
    () => parsed ? parsed.headers.map(classifyHeader) : [],
    [parsed],
  );

  // Click delegation so wikilinks in cells navigate via the SPA, not the
  // browser. Mirrors the article-level onArticleClick in DocView.
  const onClick = (e: MouseEvent) => {
    const t = e.target as HTMLElement | null;
    const a = t?.closest?.('[data-wiki]') as HTMLElement | null;
    if (!a) return;
    e.preventDefault();
    const path = a.dataset.wiki;
    if (path) onWikiClick(path, { meta: e.metaKey || e.ctrlKey });
  };

  if (!parsed) {
    // Section didn't parse as a table — fall back to letting marked render it.
    return (
      <div
        class="prose-body text-primary"
        onClick={onClick as unknown as JSX.MouseEventHandler<HTMLDivElement>}
        dangerouslySetInnerHTML={{ __html: marked.parse(resolveWikilinks(content, wikiIndex)) as string }}
      />
    );
  }

  const { headers, rows } = parsed;

  return (
    <div
      class="my-3 overflow-hidden rounded-lg border border-base bg-surface"
      onClick={onClick as unknown as JSX.MouseEventHandler<HTMLDivElement>}
    >
      <div class="overflow-x-auto">
        <table class="w-full text-[13px] text-primary border-collapse">
          <thead>
            <tr class="bg-surface-2 text-[11px] uppercase tracking-wider text-muted">
              {headers.map((h, i) => (
                <th
                  key={i}
                  class={`text-left font-semibold px-3 py-2 border-b border-base ${colHeadCls(roles[i])}`}
                >
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((row, r) => (
              <tr key={r} class="border-b border-base last:border-b-0 hover:bg-page/60 transition-colors">
                {row.map((cell, c) => (
                  <td
                    key={c}
                    class={`align-top px-3 py-2 ${colBodyCls(roles[c])}`}
                  >
                    <CellRender role={roles[c]} raw={cell} wikiIndex={wikiIndex} />
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function colHeadCls(role: ColumnRole): string {
  // Min-widths force the table to overflow its container at narrow viewports,
  // triggering horizontal scroll instead of compressing prose columns to a
  // 1-char-per-line "vertical Chinese" disaster. No `whitespace-nowrap` —
  // chips wrap, names wrap, only the prose columns get generous min-widths.
  switch (role) {
    case 'name':        return 'min-w-[6em]';
    case 'translation': return 'min-w-[8em]';
    case 'coiner':      return 'min-w-[6em]';
    case 'refs':        return 'min-w-[6em]';
    case 'works':       return 'min-w-[12em]';
    case 'evolution':   return 'min-w-[18em]';
    case 'status':      return 'min-w-[6em]';
    case 'definition':  return 'min-w-[20em]';
    default:            return '';
  }
}
function colBodyCls(role: ColumnRole): string {
  switch (role) {
    case 'name':        return 'font-semibold leading-snug';
    case 'translation': return 'text-secondary text-[12px] leading-snug';
    case 'coiner':      return 'text-secondary text-[12px] leading-snug';
    case 'refs':        return 'text-[12px]';
    case 'works':       return 'text-[12px] leading-snug';
    case 'evolution':   return 'text-secondary leading-relaxed';
    case 'status':      return 'text-[12px] leading-snug';
    case 'definition':  return 'text-secondary leading-relaxed';
    default:            return 'text-secondary leading-relaxed';
  }
}

function CellRender({ role, raw, wikiIndex }: { role: ColumnRole; raw: string; wikiIndex: Map<string, Entry> }) {
  if (role === 'refs') {
    const tokens = splitRefs(raw);
    if (tokens.length <= 1) {
      // single value — render as a single chip (or empty)
      const html = renderCellInline(raw, wikiIndex);
      return html
        ? <span class="inline-block px-1.5 py-0.5 rounded bg-page text-secondary border border-base text-[11px]" dangerouslySetInnerHTML={{ __html: html }} />
        : <span class="text-muted">—</span>;
    }
    return (
      <div class="flex flex-wrap gap-1">
        {tokens.map((tok, i) => (
          <span
            key={i}
            class="inline-block px-1.5 py-0.5 rounded bg-page text-secondary border border-base text-[11px] whitespace-nowrap"
            dangerouslySetInnerHTML={{ __html: renderCellInline(tok, wikiIndex) }}
          />
        ))}
      </div>
    );
  }
  if (role === 'coiner' || role === 'status') {
    const html = renderCellInline(raw, wikiIndex);
    return html
      ? <span class="inline-block px-1.5 py-0.5 rounded bg-accent-bg text-accent-text text-[11px]" dangerouslySetInnerHTML={{ __html: html }} />
      : <span class="text-muted">—</span>;
  }
  // Default cell: inline markdown + resolved wikilinks.
  const html = renderCellInline(raw, wikiIndex);
  return html
    ? <span dangerouslySetInnerHTML={{ __html: html }} />
    : <span class="text-muted">—</span>;
}

/** Public matcher: true if the H2 title looks like a concept-table heading. */
export function isConceptH2(title: string): boolean {
  const t = title.trim();
  return /^(关键概念表?|核心概念谱系|核心概念表?|概念谱系)$/i.test(t);
}
