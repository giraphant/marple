import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('./tauri', () => ({
  isTauri: vi.fn(),
  invoke: vi.fn(),
}));

import { isTauri, invoke } from './tauri';
import { fetchIndex } from './api';

beforeEach(() => {
  vi.resetAllMocks();
});

describe('fetchIndex', () => {
  it('uses invoke("index") under Tauri', async () => {
    (isTauri as ReturnType<typeof vi.fn>).mockReturnValue(true);
    (invoke as ReturnType<typeof vi.fn>).mockResolvedValue({ items: [{ path: 'a.md' }] });
    const out = await fetchIndex();
    expect(invoke).toHaveBeenCalledWith('index');
    expect(out).toEqual([{ path: 'a.md' }]);
  });

  it('falls back to fetch /api/index in the browser', async () => {
    (isTauri as ReturnType<typeof vi.fn>).mockReturnValue(false);
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ items: [{ path: 'b.md' }] }),
    });
    vi.stubGlobal('fetch', fetchMock);
    const out = await fetchIndex();
    expect(fetchMock).toHaveBeenCalledWith('/api/index');
    expect(out).toEqual([{ path: 'b.md' }]);
    vi.unstubAllGlobals();
  });
});
