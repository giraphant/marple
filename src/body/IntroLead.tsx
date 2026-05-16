import { useMemo } from 'preact/hooks';
import { marked } from 'marked';
import type { Entry } from '../types';
import { resolveWikilinks } from '../wiki';

/**
 * `## 思想肖像` (author profile) — opening synthesis paragraph. Render with
 * lede-paragraph treatment: slightly larger font, looser line-height, and a
 * subtle left rule for visual anchor. This is the only place in an author
 * profile where the reader gets the "elevator pitch" of who this person is,
 * so giving it a touch of typographic weight pays off.
 */

interface Props {
  content: string;
  wikiIndex: Map<string, Entry>;
}

export function IntroLead({ content, wikiIndex }: Props) {
  const html = useMemo(
    () => marked.parse(resolveWikilinks(content, wikiIndex)) as string,
    [content, wikiIndex],
  );
  return (
    <div
      class="my-3 border-l-2 border-amber-300/70 dark:border-amber-700/50 pl-4 text-[15px] leading-[1.85] text-primary [&_p:first-child]:mt-0 [&_p:last-child]:mb-0"
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}

export function isIntroLeadH2(title: string): boolean {
  return /^思想肖像$/.test(title.trim());
}
