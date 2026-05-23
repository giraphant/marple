import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

vi.mock('./tauri', () => ({
  isTauri: vi.fn(),
  invoke: vi.fn(),
}));

import { isTauri, invoke } from './tauri';
import { fetchIndex } from './api';

beforeEach(() => {
  vi.resetAllMocks();
});

afterEach(() => {
  vi.unstubAllGlobals();
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
  });
});

import { fetchEntry } from './api';

describe('fetchEntry', () => {
  it('uses invoke("entry", {path}) under Tauri', async () => {
    (isTauri as ReturnType<typeof vi.fn>).mockReturnValue(true);
    (invoke as ReturnType<typeof vi.fn>).mockResolvedValue({ entry: { path: 'x.md' } });
    const out = await fetchEntry('x.md');
    expect(invoke).toHaveBeenCalledWith('entry', { path: 'x.md' });
    expect(out).toEqual({ path: 'x.md' });
  });

  it('returns null when invoke yields no entry', async () => {
    (isTauri as ReturnType<typeof vi.fn>).mockReturnValue(true);
    (invoke as ReturnType<typeof vi.fn>).mockResolvedValue({ entry: null });
    expect(await fetchEntry('missing.md')).toBeNull();
  });
});

import { fetchEntryText } from './api';

describe('fetchEntryText', () => {
  it('uses invoke("entry_text", {path}) under Tauri', async () => {
    (isTauri as ReturnType<typeof vi.fn>).mockReturnValue(true);
    (invoke as ReturnType<typeof vi.fn>).mockResolvedValue('---\ntitle: x\n---\nbody');
    const out = await fetchEntryText('vault/notes/x.md');
    expect(invoke).toHaveBeenCalledWith('entry_text', { path: 'vault/notes/x.md' });
    expect(out).toContain('body');
  });
});

import { listFiles } from './api';

describe('listFiles', () => {
  it('uses invoke("files", {since}) under Tauri', async () => {
    (isTauri as ReturnType<typeof vi.fn>).mockReturnValue(true);
    (invoke as ReturnType<typeof vi.fn>).mockResolvedValue({ items: [{ path: 'a.md', mtime: 2 }], total: 5 });
    const out = await listFiles(1);
    expect(invoke).toHaveBeenCalledWith('files', { since: 1 });
    expect(out).toEqual({ items: [{ path: 'a.md', mtime: 2 }], total: 5 });
  });

  it('passes since=undefined for a full listing', async () => {
    (isTauri as ReturnType<typeof vi.fn>).mockReturnValue(true);
    (invoke as ReturnType<typeof vi.fn>).mockResolvedValue({ items: [], total: 0 });
    await listFiles();
    expect(invoke).toHaveBeenCalledWith('files', { since: undefined });
  });
});

import { listTrash } from './api';

describe('listTrash', () => {
  it('uses invoke("trash_list") under Tauri', async () => {
    (isTauri as ReturnType<typeof vi.fn>).mockReturnValue(true);
    (invoke as ReturnType<typeof vi.fn>).mockResolvedValue({ items: [{ name: 'n.md' }] });
    const out = await listTrash();
    expect(invoke).toHaveBeenCalledWith('trash_list');
    expect(out).toEqual([{ name: 'n.md' }]);
  });
});
