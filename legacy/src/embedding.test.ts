import { describe, it, expect } from 'vitest';
import { formatEmbedStatus, type EmbedStatus } from './embedding';

const base: EmbedStatus = {
  phase: 'idle',
  embedded: 0,
  total: 0,
  vectorsExist: false,
  vectorsCount: null,
  model: null,
  completedAt: null,
  startedAt: null,
  error: null,
};

describe('formatEmbedStatus', () => {
  it('shows "not built" when idle with no vectors', () => {
    const r = formatEmbedStatus(base);
    expect(r.tone).toBe('idle');
    expect(r.label).toContain('未构建');
  });

  it('shows the on-disk count when idle but vectors already exist', () => {
    const r = formatEmbedStatus({ ...base, vectorsExist: true, vectorsCount: 12539 });
    expect(r.tone).toBe('done');
    expect(r.label).toContain('12539');
  });

  it('shows live progress while running', () => {
    const r = formatEmbedStatus({ ...base, phase: 'running', embedded: 1200, total: 12539 });
    expect(r.tone).toBe('running');
    expect(r.label).toContain('1200');
    expect(r.label).toContain('12539');
  });

  it('shows a preparing state while running before total is known', () => {
    const r = formatEmbedStatus({ ...base, phase: 'running', embedded: 0, total: 0 });
    expect(r.tone).toBe('running');
    expect(r.label).toContain('构建中');
  });

  it('shows done with the built count', () => {
    const r = formatEmbedStatus({
      ...base, phase: 'done', vectorsExist: true, vectorsCount: 12539, model: 'BAAI/bge-m3',
    });
    expect(r.tone).toBe('done');
    expect(r.label).toContain('12539');
  });

  it('shows a clear message when done but nothing was embeddable', () => {
    const r = formatEmbedStatus({ ...base, phase: 'done', vectorsExist: true, vectorsCount: 0 });
    expect(r.tone).toBe('done');
    expect(r.label).toContain('无可嵌入');
  });

  it('surfaces the error when failed', () => {
    const r = formatEmbedStatus({ ...base, phase: 'failed', error: 'init BGE-M3: timeout' });
    expect(r.tone).toBe('error');
    expect(r.label).toContain('timeout');
  });
});

describe('isEmbedRunning', () => {
  it('is true only for the running phase', async () => {
    const { isEmbedRunning } = await import('./embedding');
    expect(isEmbedRunning({ ...base, phase: 'running' })).toBe(true);
    expect(isEmbedRunning({ ...base, phase: 'idle' })).toBe(false);
    expect(isEmbedRunning({ ...base, phase: 'done' })).toBe(false);
    expect(isEmbedRunning({ ...base, phase: 'failed' })).toBe(false);
  });
});
