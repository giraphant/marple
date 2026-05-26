import { describe, it, expect } from 'vitest';
import { extractHeadings } from './doc-outline';

describe('extractHeadings', () => {
  it('extracts multi-level headings with 1-based line numbers', () => {
    const md = [
      '# Title',          // line 1
      '',                 // 2
      'intro paragraph',  // 3
      '## Section A',     // 4
      'body',             // 5
      '### Sub',          // 6
      '## Section B',     // 7
    ].join('\n');
    expect(extractHeadings(md)).toEqual([
      { level: 1, text: 'Title', line: 1 },
      { level: 2, text: 'Section A', line: 4 },
      { level: 3, text: 'Sub', line: 6 },
      { level: 2, text: 'Section B', line: 7 },
    ]);
  });

  it('ignores # inside fenced code blocks', () => {
    const md = [
      '# Real',           // 1
      '```',              // 2
      '# not a heading',  // 3
      '## also not',      // 4
      '```',              // 5
      '## Real Two',      // 6
    ].join('\n');
    expect(extractHeadings(md).map(h => h.text)).toEqual(['Real', 'Real Two']);
  });

  it('handles ~~~ fences and trailing closing hashes', () => {
    const md = [
      '~~~',          // 1
      '# nope',       // 2
      '~~~',          // 3
      '## Heading ##',// 4
    ].join('\n');
    const hs = extractHeadings(md);
    expect(hs).toEqual([{ level: 2, text: 'Heading', line: 4 }]);
  });

  it('requires a space after the hashes (not #tag)', () => {
    expect(extractHeadings('#nospace\n# yes')).toEqual([{ level: 1, text: 'yes', line: 2 }]);
  });

  it('keeps a trailing # with no preceding space (# C#) but strips a real closing sequence', () => {
    expect(extractHeadings('# C#')).toEqual([{ level: 1, text: 'C#', line: 1 }]);
    expect(extractHeadings('# Heading ##')).toEqual([{ level: 1, text: 'Heading', line: 1 }]);
  });

  it('a longer opening fence is not closed by a shorter one', () => {
    const md = [
      '````',           // 1: 4-tick open
      '# still code',   // 2
      '```',            // 3: 3-tick, too short to close
      '# also code',    // 4
      '````',           // 5: closes the 4-tick fence
      '# Real',         // 6
    ].join('\n');
    expect(extractHeadings(md).map(h => h.text)).toEqual(['Real']);
  });

  it('skips empty headings (hashes with no text)', () => {
    expect(extractHeadings('# \n## Real')).toEqual([{ level: 2, text: 'Real', line: 2 }]);
  });

  it('returns empty for heading-free text', () => {
    expect(extractHeadings('just\nplain\ntext')).toEqual([]);
  });
});
