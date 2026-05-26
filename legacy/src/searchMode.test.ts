import { describe, it, expect } from 'vitest';
import { nextSearchMode, SEARCH_MODES, SEARCH_MODE_META, sourceBadge } from './searchMode';

describe('nextSearchMode', () => {
  it('cycles fast -> balanced -> deep -> fast', () => {
    expect(nextSearchMode('fast')).toBe('balanced');
    expect(nextSearchMode('balanced')).toBe('deep');
    expect(nextSearchMode('deep')).toBe('fast');
  });

  it('lists the three modes in fast→balanced→deep order', () => {
    expect(SEARCH_MODES).toEqual(['fast', 'balanced', 'deep']);
  });

  it('has display metadata for every mode', () => {
    for (const mode of SEARCH_MODES) {
      expect(SEARCH_MODE_META[mode].label.length).toBeGreaterThan(0);
      expect(SEARCH_MODE_META[mode].placeholder.length).toBeGreaterThan(0);
      expect(SEARCH_MODE_META[mode].loading.length).toBeGreaterThan(0);
    }
  });
});

describe('sourceBadge', () => {
  it('badges the vector-distinctive sources', () => {
    expect(sourceBadge('hybrid')).toEqual({ label: '混合' });
    expect(sourceBadge('vec')).toEqual({ label: '向量' });
  });

  it('matches on the leading token so suffixed sources still badge', () => {
    expect(sourceBadge('hybrid (lex-fallback)')).toEqual({ label: '混合' });
  });

  it('returns null for plain lexical sources and undefined', () => {
    for (const s of ['phrase', 'fulltext', 'expanded', 'fuzzy', 'substring']) {
      expect(sourceBadge(s)).toBeNull();
    }
    expect(sourceBadge(undefined)).toBeNull();
  });
});
