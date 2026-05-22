import { describe, it, expect } from 'vitest';
import { nextSearchMode, SEARCH_MODES, SEARCH_MODE_META } from './searchMode';

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
