import { describe, it, expect, vi, afterEach } from 'vitest';
import { openInEditor } from './api';

afterEach(() => vi.restoreAllMocks());

describe('openInEditor (QUA-72)', () => {
  it('POSTs the path + app as JSON to /api/open-in-editor', async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ ok: true }), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    await openInEditor('vault/notes/hello.md', 'Visual Studio Code');

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('/api/open-in-editor');
    expect(init.method).toBe('POST');
    expect(JSON.parse(init.body as string)).toEqual({
      path: 'vault/notes/hello.md',
      app: 'Visual Studio Code',
    });
  });

  it('throws on a non-ok response so callers can surface the failure', async () => {
    const fetchMock = vi.fn(async () => new Response('boom', { status: 500 }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(openInEditor('vault/notes/x.md', '')).rejects.toThrow(/open in editor failed: 500/);
  });
});
