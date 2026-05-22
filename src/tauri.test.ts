import { describe, it, expect, vi, afterEach } from 'vitest';

afterEach(() => {
  vi.unstubAllGlobals();
  vi.resetModules();
});

describe('isTauri', () => {
  it('is false in a plain browser/test env', async () => {
    const { isTauri } = await import('./tauri');
    expect(isTauri()).toBe(false);
  });

  it('is true when the Tauri internals global is present', async () => {
    vi.stubGlobal('window', { __TAURI_INTERNALS__: {} });
    const { isTauri } = await import('./tauri');
    expect(isTauri()).toBe(true);
  });
});
