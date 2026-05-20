import { describe, it, expect } from 'vitest';
import { computeDocStats, countWords } from './doc-stats';

describe('countWords', () => {
  it('counts each CJK ideograph as one word', () => {
    expect(countWords('身体技术')).toBe(4);
  });

  it('counts a run of latin/digits as one word', () => {
    expect(countWords('hello world 2020')).toBe(3);
  });

  it('mixes CJK and latin', () => {
    expect(countWords('技术物 X 与 environment E')).toBe(3 /*技术物*/ + 1 /*X*/ + 1 /*与*/ + 1 /*environment*/ + 1 /*E*/);
  });
});

describe('computeDocStats', () => {
  it('counts chars (incl/excl whitespace), words, paragraphs', () => {
    const body = '第一段 has words.\n\n第二段 here.';
    const s = computeDocStats(body);
    expect(s.paragraphs).toBe(2);
    expect(s.chars).toBe([...body].length);
    expect(s.charsNoSpace).toBeLessThan(s.chars);
    expect(s.words).toBeGreaterThan(0);
  });

  it('reading time is at least 1 minute for non-empty, 0 for empty', () => {
    expect(computeDocStats('').minutes).toBe(0);
    expect(computeDocStats('一些字').minutes).toBe(1);
  });

  it('reading time scales with length', () => {
    const long = '字'.repeat(3000); // 3000 words / 300wpm = 10 min
    expect(computeDocStats(long).minutes).toBe(10);
  });

  it('collapses blank-line-separated blocks into paragraphs', () => {
    expect(computeDocStats('a\n\n\n\nb').paragraphs).toBe(2);
    expect(computeDocStats('single block\nwith two lines').paragraphs).toBe(1);
  });
});
