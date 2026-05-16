import { useMemo } from 'preact/hooks';
import { marked } from 'marked';
import type { Entry } from '../types';
import { resolveWikilinks } from '../wiki';

/**
 * Vertical-timeline renderer for `## 章节间逻辑`.
 *
 * The vault's book overviews follow a recurring informal pattern in this
 * section:
 *
 *   <prelude paragraph: "全书 14 章构成了…">
 *
 *   **第一层：框架建构（第1-2章）**。<description>
 *   **第二层：制度性度量化（第3-4章）**。<description>
 *   **第三层：自我追踪的经验多样性（第5-9章）**。<description>
 *
 *   <postscript paragraph: closing reflection on inter-chapter dialogue>
 *
 * Each `**TITLE**` heading paragraph becomes a timeline node; the prelude
 * and postscript render as regular paragraphs above/below. With fewer than
 * 2 nodes we fall back to plain markdown, since the timeline UI only
 * earns its keep when there's actually a sequence to step through.
 *
 * The pattern is informal (not in the SPEC body grammar), so we keep this
 * detection conservative: title must be the very first thing in a paragraph,
 * surrounded by `**…**`, optionally followed by 。 or :/： before the body.
 */

const BOLD_HEAD_RE = /^\*\*([^*\n]+?)\*\*[。:：]?\s*/;

interface FlowNode {
  /** The bold-headed label of this node, sans `**` markers. */
  title: string;
  /** The remaining body text after the title. */
  body: string;
}

interface ParsedFlow {
  prelude: string;
  nodes: FlowNode[];
  postscript: string;
}

function parseFlow(content: string): ParsedFlow {
  const paragraphs = content.split(/\n{2,}/).map(p => p.trim()).filter(Boolean);
  const preludeParts: string[] = [];
  const nodes: FlowNode[] = [];
  // Non-node paragraphs encountered after the last node we saw. If a new
  // node appears later, these merge into the previous node's body; if no
  // more nodes appear, they become the postscript.
  let trailing: string[] = [];
  let seenFirstNode = false;

  for (const p of paragraphs) {
    const m = p.match(BOLD_HEAD_RE);
    if (m) {
      if (trailing.length > 0 && nodes.length > 0) {
        nodes[nodes.length - 1].body += '\n\n' + trailing.join('\n\n');
      }
      trailing = [];
      // Some titles end with 。 inside the bold (`**第一弧线 … 建立理论框架。**`)
      // because authors place punctuation before closing `**`. Strip it.
      const title = m[1].trim().replace(/[。．.：:]+$/, '');
      const body = p.slice(m[0].length).trim();
      nodes.push({ title, body });
      seenFirstNode = true;
    } else if (!seenFirstNode) {
      preludeParts.push(p);
    } else {
      trailing.push(p);
    }
  }

  return {
    prelude: preludeParts.join('\n\n'),
    nodes,
    postscript: trailing.join('\n\n'),
  };
}

interface Props {
  content: string;
  wikiIndex: Map<string, Entry>;
}

export function ChapterFlow({ content, wikiIndex }: Props) {
  const parsed = useMemo(() => parseFlow(content), [content]);

  if (parsed.nodes.length < 2) {
    // Not enough timeline nodes — render as plain markdown so we don't
    // create a "single-node timeline" that looks like a UX accident.
    return <Marked content={content} wikiIndex={wikiIndex} />;
  }

  return (
    <div class="my-3">
      {parsed.prelude && (
        <div class="mb-3">
          <Marked content={parsed.prelude} wikiIndex={wikiIndex} />
        </div>
      )}
      {/* `!pl-0` *must* be !important — `.prose-body ol { padding-left: 1.5em }`
          has higher specificity (class + element) than `.pl-0` (class), so
          without `!` the line gets pushed 24px to the left of the dots and
          disappears outside the prose-body's left edge. `[&>li]:my-0` keeps
          the LI margins from prose-body out of the timeline gap math. */}
      <ol class="relative my-3 ml-3 !pl-0 list-none border-l-2 border-amber-300 dark:border-amber-700/60 space-y-5 [&>li]:my-0">
        {parsed.nodes.map((n, i) => (
          <li key={i} class="relative pl-6">
            {/* `-left-px` + `-translate-x-1/2` puts the dot's center on the
                2-px border's center; `ring-4 ring-page` masks the line so it
                visually "passes through" the dot (classic timeline trick). */}
            <span
              aria-hidden="true"
              class="absolute -left-px top-[0.45em] -translate-x-1/2 w-2.5 h-2.5 rounded-full bg-amber-400 dark:bg-amber-500 ring-4 ring-page"
            />
            <div class="text-[14px] font-semibold text-primary leading-snug">
              {n.title}
            </div>
            {n.body && (
              <div class="mt-1.5 text-secondary leading-relaxed [&_p]:my-1">
                <Marked content={n.body} wikiIndex={wikiIndex} />
              </div>
            )}
          </li>
        ))}
      </ol>
      {parsed.postscript && (
        <div class="mt-3 text-secondary">
          <Marked content={parsed.postscript} wikiIndex={wikiIndex} />
        </div>
      )}
    </div>
  );
}

function Marked({ content, wikiIndex }: { content: string; wikiIndex: Map<string, Entry> }) {
  const html = useMemo(
    () => marked.parse(resolveWikilinks(content, wikiIndex)) as string,
    [content, wikiIndex],
  );
  return <div dangerouslySetInnerHTML={{ __html: html }} />;
}

export function isChapterFlowH2(title: string): boolean {
  // Accept both 章节逻辑 and 章节间逻辑 — the data has drifted between the
  // two; SPEC v0.2 uses 章节间逻辑 but many recent books use 章节逻辑.
  // Also matches `## 学术轨迹` (author profiles) which uses the same
  // `**1980 年代：…**` bold-prefixed paragraph shape — phases on a career
  // arc render naturally as timeline nodes.
  const t = title.trim();
  return /^章节(间)?逻辑$/.test(t) || /^学术轨迹$/.test(t);
}
