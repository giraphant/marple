import { describe, it, expect } from 'vitest';
import type { Entry } from './types';
import { sortEntries, applyExtraFilters, defaultDirFor } from './list-sort';

function entry(over: Partial<Entry>): Entry {
  return {
    path: over.path ?? 'vault/x.md',
    type: over.type ?? 'paper-analysis',
    book: null,
    title: null,
    author: null,
    year: null,
    rating: null,
    rating_score: 0,
    themes: null,
    topic: null,
    source: null,
    doi: null,
    chapters_analyzed: null,
    annotates: null,
    created: null,
    preview: '',
    ...over,
  };
}

describe('sortEntries', () => {
  it('default leaves order untouched (same reference)', () => {
    const list = [entry({ path: 'a' }), entry({ path: 'b' })];
    expect(sortEntries(list, 'default', 'asc')).toBe(list);
  });

  it('sorts by title asc/desc with locale compare', () => {
    const list = [
      entry({ path: 'b', title: 'Body' }),
      entry({ path: 'a', title: 'Affect' }),
      entry({ path: 'c', title: 'Cyborg' }),
    ];
    expect(sortEntries(list, 'title', 'asc').map(e => e.path)).toEqual(['a', 'b', 'c']);
    expect(sortEntries(list, 'title', 'desc').map(e => e.path)).toEqual(['c', 'b', 'a']);
  });

  it('puts empty titles last regardless of direction', () => {
    const list = [
      entry({ path: 'empty', title: null }),
      entry({ path: 'a', title: 'Alpha' }),
      entry({ path: 'z', title: 'Zeta' }),
    ];
    expect(sortEntries(list, 'title', 'asc').map(e => e.path)).toEqual(['a', 'z', 'empty']);
    expect(sortEntries(list, 'title', 'desc').map(e => e.path)).toEqual(['z', 'a', 'empty']);
  });

  it('sorts by year numerically (string/number mixed), empties last', () => {
    const list = [
      entry({ path: 'old', year: '1999' }),
      entry({ path: 'none', year: null }),
      entry({ path: 'new', year: 2021 }),
    ];
    expect(sortEntries(list, 'year', 'desc').map(e => e.path)).toEqual(['new', 'old', 'none']);
    expect(sortEntries(list, 'year', 'asc').map(e => e.path)).toEqual(['old', 'new', 'none']);
  });

  it('sorts by rating_score', () => {
    const list = [
      entry({ path: 'mid', rating_score: 3 }),
      entry({ path: 'top', rating_score: 5 }),
      entry({ path: 'none', rating_score: 0 }),
    ];
    expect(sortEntries(list, 'rating', 'desc').map(e => e.path)).toEqual(['top', 'mid', 'none']);
  });

  it('sorts by updated (mtime), empties last', () => {
    const list = [
      entry({ path: 'a', mtime: 100 }),
      entry({ path: 'b', mtime: 300 }),
      entry({ path: 'none', mtime: null }),
    ];
    expect(sortEntries(list, 'updated', 'desc').map(e => e.path)).toEqual(['b', 'a', 'none']);
    expect(sortEntries(list, 'updated', 'asc').map(e => e.path)).toEqual(['a', 'b', 'none']);
  });

  it('is stable: equal keys keep input order', () => {
    const list = [
      entry({ path: '1', title: 'Same' }),
      entry({ path: '2', title: 'Same' }),
      entry({ path: '3', title: 'Same' }),
    ];
    expect(sortEntries(list, 'title', 'asc').map(e => e.path)).toEqual(['1', '2', '3']);
    expect(sortEntries(list, 'title', 'desc').map(e => e.path)).toEqual(['1', '2', '3']);
  });

  it('does not mutate the input array', () => {
    const list = [entry({ path: 'b', title: 'B' }), entry({ path: 'a', title: 'A' })];
    const before = list.map(e => e.path);
    sortEntries(list, 'title', 'asc');
    expect(list.map(e => e.path)).toEqual(before);
  });
});

describe('applyExtraFilters', () => {
  const list = [
    entry({ path: 'h', author: 'Donna Haraway', has_pdf: true }),
    entry({ path: 'i', author: 'Don Ihde', has_pdf: false }),
    entry({ path: 'n', author: null, has_pdf: true }),
  ];

  it('no filters returns the same reference', () => {
    expect(applyExtraFilters(list, {})).toBe(list);
  });

  it('author substring is case-insensitive', () => {
    expect(applyExtraFilters(list, { author: 'don' }).map(e => e.path)).toEqual(['h', 'i']);
    expect(applyExtraFilters(list, { author: 'haraway' }).map(e => e.path)).toEqual(['h']);
  });

  it('hasPdfOnly keeps only entries with a pdf', () => {
    expect(applyExtraFilters(list, { hasPdfOnly: true }).map(e => e.path)).toEqual(['h', 'n']);
  });

  it('filters combine', () => {
    expect(applyExtraFilters(list, { author: 'don', hasPdfOnly: true }).map(e => e.path)).toEqual(['h']);
  });
});

describe('defaultDirFor', () => {
  it('text keys default asc, numeric keys default desc', () => {
    expect(defaultDirFor('title')).toBe('asc');
    expect(defaultDirFor('author')).toBe('asc');
    expect(defaultDirFor('year')).toBe('desc');
    expect(defaultDirFor('rating')).toBe('desc');
    expect(defaultDirFor('updated')).toBe('desc');
  });
});
