import { describe, it, expect } from 'vitest';
import { saveDecision } from './live';

describe('saveDecision', () => {
  it('writes when the on-disk file matches what we last loaded/saved', () => {
    const raw = '---\ntype: note\n---\n\nhello';
    expect(saveDecision(raw, raw)).toBe('write');
  });

  it('flags a conflict when the on-disk file changed underneath us', () => {
    const mine = '---\ntype: note\n---\n\nhello';
    const disk = '---\ntype: note\n---\n\nhello (edited in another window)';
    expect(saveDecision(mine, disk)).toBe('conflict');
  });

  it('flags a conflict when the on-disk content could not be read (null)', () => {
    const mine = '---\ntype: note\n---\n\nhello';
    expect(saveDecision(mine, null)).toBe('conflict');
  });
});
