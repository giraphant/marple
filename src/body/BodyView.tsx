import { useMemo } from 'preact/hooks';
import type { JSX } from 'preact';
import { marked } from 'marked';
import type { Entry } from '../types';
import { resolveWikilinks } from '../wiki';
import { splitSections, type Segment } from './sections';
import { ConceptTable, isConceptH2 } from './ConceptTable';
import { QuoteCards, isQuoteH2 } from './QuoteCards';
import { ProjectTabs, isProjectTabsH2 } from './ProjectTabs';
import { ChapterFlow, isChapterFlowH2 } from './ChapterFlow';
import { ReadingList, isReadingListH2 } from './ReadingList';
import { WorksList, isWorksH2 } from './WorksList';
import { IntroLead, isIntroLeadH2 } from './IntroLead';
import { TheoryNetwork, isTheoryNetworkH2 } from './TheoryNetwork';

/**
 * Segment-aware body renderer for non-editable docs.
 *
 * Routes each `## H2` to a specialised renderer when the title matches a
 * known typed-block (e.g. concept tables). Sections that aren't typed —
 * including the prelude before the first H2 — render through `marked` so
 * paragraphs, lists, blockquotes, sub-headings, code etc. all keep working.
 *
 * Wikilinks (`[[…]]`) are resolved once per segment so wikilinks inside
 * tables / lists / paragraphs all become clickable. `data-wiki` clicks are
 * delegated up so the SPA tab system handles navigation rather than the
 * browser.
 */

interface Props {
  entry: Entry;
  body: string;
  wikiIndex: Map<string, Entry>;
  onWikiClick: (path: string, modifiers: { meta: boolean }) => void;
}

export function BodyView({ entry, body, wikiIndex, onWikiClick }: Props) {
  const segments = useMemo(() => splitSections(body), [body]);

  // Anchor-style delegation so wikilinks inside marked-rendered HTML still
  // navigate via the SPA. Each marked segment gets this same handler.
  const onClickAnchor = (e: MouseEvent) => {
    const target = e.target as HTMLElement | null;
    const a = target?.closest?.('[data-wiki]') as HTMLElement | null;
    if (!a) return;
    e.preventDefault();
    const path = a.dataset.wiki;
    if (path) onWikiClick(path, { meta: e.metaKey || e.ctrlKey });
  };

  return (
    <article
      class="prose-body text-primary px-8 py-6 mx-auto max-w-5xl"
      onClick={onClickAnchor as unknown as JSX.MouseEventHandler<HTMLElement>}
    >
      {segments.map((seg, i) => (
        <SegmentRender
          key={i}
          entry={entry}
          segment={seg}
          wikiIndex={wikiIndex}
          onWikiClick={onWikiClick}
        />
      ))}
    </article>
  );
}

function SegmentRender({ entry, segment, wikiIndex, onWikiClick }: {
  entry: Entry;
  segment: Segment;
  wikiIndex: Map<string, Entry>;
  onWikiClick: (path: string, modifiers: { meta: boolean }) => void;
}) {
  if (segment.kind === 'prelude') {
    return <MarkedFragment content={segment.content} wikiIndex={wikiIndex} />;
  }

  const { title, content } = segment;

  if (isConceptH2(title)) {
    return (
      <section>
        <h2>{title}</h2>
        <ConceptTable content={content} wikiIndex={wikiIndex} onWikiClick={onWikiClick} />
      </section>
    );
  }

  if (isQuoteH2(title)) {
    return (
      <section>
        <h2>{title}</h2>
        <QuoteCards content={content} wikiIndex={wikiIndex} />
      </section>
    );
  }

  if (isProjectTabsH2(title)) {
    return (
      <section>
        <h2>{title}</h2>
        <ProjectTabs content={content} wikiIndex={wikiIndex} entryKey={entry.path} />
      </section>
    );
  }

  if (isChapterFlowH2(title)) {
    return (
      <section>
        <h2>{title}</h2>
        <ChapterFlow content={content} wikiIndex={wikiIndex} />
      </section>
    );
  }

  if (isReadingListH2(title)) {
    return (
      <section>
        <h2>{title}</h2>
        <ReadingList content={content} wikiIndex={wikiIndex} />
      </section>
    );
  }

  if (isWorksH2(title)) {
    return (
      <section>
        <h2>{title}</h2>
        <WorksList content={content} wikiIndex={wikiIndex} onWikiClick={onWikiClick} />
      </section>
    );
  }

  if (isIntroLeadH2(title)) {
    return (
      <section>
        <h2>{title}</h2>
        <IntroLead content={content} wikiIndex={wikiIndex} />
      </section>
    );
  }

  if (isTheoryNetworkH2(title)) {
    return (
      <section>
        <h2>{title}</h2>
        <TheoryNetwork content={content} wikiIndex={wikiIndex} onWikiClick={onWikiClick} />
      </section>
    );
  }

  // Unknown H2: render the whole thing (heading + content) through marked.
  return <MarkedFragment content={`## ${title}\n\n${content}`} wikiIndex={wikiIndex} />;
}

function MarkedFragment({ content, wikiIndex }: { content: string; wikiIndex: Map<string, Entry> }) {
  const html = useMemo(
    () => marked.parse(resolveWikilinks(content, wikiIndex)) as string,
    [content, wikiIndex],
  );
  return <div dangerouslySetInnerHTML={{ __html: html }} />;
}
