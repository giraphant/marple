import { useMemo, useState, useEffect } from 'preact/hooks';
import { marked } from 'marked';
import type { Entry } from '../types';
import { resolveWikilinks } from '../wiki';

/**
 * Multi-project tab renderer.
 *
 * Targets `## 与项目主题的关联` / `## 项目关联` / `## 相关引用文献` H2 sections.
 * Per SPEC §4.5 these are typed `h3-project-tabs` — each `### H3` is one
 * project's view of the same entity, and the reader should let the user
 * flip between them rather than scrolling through every project sequentially.
 *
 * Strategy:
 * - Split content on `### H3` boundaries.
 * - With ≥2 tabs: render as a tab bar + active tab body.
 * - With 0 or 1 tabs: just render the whole section through marked
 *   (no value in adding a single-tab strip).
 *
 * Active-tab state is component-local; switching entries unmounts the
 * component so each doc starts fresh on its first tab.
 */

interface Tab {
  title: string;
  content: string;
}

function splitH3Tabs(content: string): Tab[] {
  const lines = content.split(/\r?\n/);
  const tabs: Tab[] = [];
  let curTitle: string | null = null;
  let buf: string[] = [];
  let preludeBuf: string[] = [];

  const flush = () => {
    if (curTitle !== null) {
      tabs.push({ title: curTitle, content: buf.join('\n').trim() });
      buf = [];
    }
  };

  for (const line of lines) {
    const h3 = line.match(/^###\s+(.+?)\s*$/);
    if (h3) {
      flush();
      curTitle = h3[1].trim();
      continue;
    }
    if (curTitle === null) preludeBuf.push(line);
    else buf.push(line);
  }
  flush();
  // If there's prelude text before the first H3, prepend it as a synthetic
  // "概述" tab so it doesn't get lost.
  const prelude = preludeBuf.join('\n').trim();
  if (prelude && tabs.length > 0) tabs.unshift({ title: '概述', content: prelude });
  return tabs;
}

interface Props {
  content: string;
  wikiIndex: Map<string, Entry>;
  /** Per-entry key so the active tab resets between docs but persists across
   *  re-renders within one. */
  entryKey: string;
}

export function ProjectTabs({ content, wikiIndex, entryKey }: Props) {
  const tabs = useMemo(() => splitH3Tabs(content), [content]);
  const [active, setActive] = useState(0);
  useEffect(() => { setActive(0); }, [entryKey]);

  if (tabs.length < 2) {
    // 0 or 1 project — fall through to plain marked render.
    return <Plain content={content} wikiIndex={wikiIndex} />;
  }

  const cur = tabs[Math.min(active, tabs.length - 1)];

  return (
    <div class="my-3 border border-base rounded-lg overflow-hidden bg-surface">
      <div role="tablist" class="flex flex-wrap gap-px bg-surface-2 px-2 pt-2">
        {tabs.map((t, i) => {
          const isActive = i === active;
          return (
            <button
              key={i}
              role="tab"
              aria-selected={isActive}
              onClick={() => setActive(i)}
              class={`text-[12px] px-3 py-1.5 rounded-t-md -mb-px border border-b-0 transition ${
                isActive
                  ? 'bg-surface border-base text-primary font-medium'
                  : 'border-transparent text-secondary hover:text-primary hover:bg-surface/60'
              }`}
            >
              {t.title}
            </button>
          );
        })}
      </div>
      <div class="px-4 py-3 border-t border-base">
        <Plain content={cur.content} wikiIndex={wikiIndex} />
      </div>
    </div>
  );
}

function Plain({ content, wikiIndex }: { content: string; wikiIndex: Map<string, Entry> }) {
  const html = useMemo(
    () => marked.parse(resolveWikilinks(content, wikiIndex)) as string,
    [content, wikiIndex],
  );
  return <div dangerouslySetInnerHTML={{ __html: html }} />;
}

export function isProjectTabsH2(title: string): boolean {
  const t = title.trim();
  if (/^项目关联$/.test(t)) return true;
  if (/^与.*关联(性评估)?$/.test(t)) return true;
  if (/^与.*主题/.test(t)) return true;
  if (/^相关引用文献$/.test(t)) return true;
  if (/^直接相关的.*引用文献$/.test(t)) return true;
  return false;
}
