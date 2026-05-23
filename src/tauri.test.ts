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

describe('invoke', () => {
  it('rethrows a string rejection as an Error naming the command', async () => {
    vi.doMock('@tauri-apps/api/core', () => ({
      invoke: vi.fn().mockRejectedValue('boom'),
    }));
    const { invoke } = await import('./tauri');
    await expect(invoke('index')).rejects.toThrow(/IPC index failed: boom/);
    await expect(invoke('index')).rejects.toBeInstanceOf(Error);
    vi.doUnmock('@tauri-apps/api/core');
  });
});
