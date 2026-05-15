import { useEffect, useState, useCallback } from 'preact/hooks';
import { listTrash, restoreTrash, purgeTrash, type TrashItem } from '../api';

interface Props {
  /** Called after a successful restore so the parent can refresh entries. */
  onRestored: (restoredPath: string) => void;
}

export function TrashView({ onRestored }: Props) {
  const [items, setItems] = useState<TrashItem[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null); // name being acted on

  const refresh = useCallback(async () => {
    try {
      setErr(null);
      const list = await listTrash();
      setItems(list);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    }
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  const onRestore = async (name: string) => {
    setBusy(name); setErr(null);
    try {
      const restored = await restoreTrash(name);
      await refresh();
      onRestored(restored);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const onPurge = async (name: string) => {
    if (!window.confirm(`永久删除「${name}」？此操作不可恢复。`)) return;
    setBusy(name); setErr(null);
    try {
      await purgeTrash(name);
      await refresh();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  return (
    <div class="flex-1 flex flex-col min-h-0">
      <header class="bg-surface/95 backdrop-blur border-b border-base sticky top-0 z-10">
        <div class="px-6 py-3 flex items-center gap-4">
          <div class="flex items-baseline gap-2 min-w-0">
            <div class="text-[18px] font-semibold tracking-tight text-primary">回收站</div>
            <div class="text-[11px] text-muted tabular-nums">
              {items ? items.length : '…'}
            </div>
          </div>
          <button
            onClick={refresh}
            class="text-[11px] text-muted hover:text-primary px-2 py-0.5 rounded hover:bg-surface-2"
            title="刷新"
          >刷新</button>
        </div>
      </header>

      <main class="flex-1 overflow-auto scrollbar-thin px-6 py-4">
        {err && (
          <div class="text-[12px] text-red-700 dark:text-red-300 bg-red-50 border border-red-200 dark:border-red-900 rounded px-3 py-2 mb-4">
            {err}
          </div>
        )}

        {!items && !err && (
          <div class="text-sm text-muted py-10 text-center">加载中…</div>
        )}

        {items && items.length === 0 && (
          <div class="text-sm text-muted py-10 text-center">回收站为空</div>
        )}

        {items && items.length > 0 && (
          <div class="space-y-1">
            {items.map(it => (
              <div
                key={it.name}
                class="flex items-center gap-3 px-3 py-2 rounded border border-base bg-surface hover:border-strong"
              >
                <div class="flex-1 min-w-0">
                  <div class="text-[13px] text-primary truncate">
                    {it.originalBase ?? it.name}
                  </div>
                  <div class="text-[11px] text-muted mt-0.5">
                    <span class="font-mono">{it.name}</span>
                    {it.ts && <span class="ml-2 text-muted">删除于 {prettyTs(it.ts)}</span>}
                    <span class="ml-2 text-muted tabular-nums">{prettySize(it.size)}</span>
                  </div>
                </div>
                <button
                  onClick={() => onRestore(it.name)}
                  disabled={busy === it.name}
                  class="text-[12px] px-2.5 py-1 rounded bg-inverse text-inverse-fg hover:bg-inverse/80 disabled:opacity-50"
                >恢复</button>
                <button
                  onClick={() => onPurge(it.name)}
                  disabled={busy === it.name}
                  class="text-[12px] px-2.5 py-1 rounded border border-red-200 dark:border-red-900 text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950/30 disabled:opacity-50"
                >永久删除</button>
              </div>
            ))}
          </div>
        )}
      </main>
    </div>
  );
}

function prettyTs(ts: string): string {
  // ts is like 2026-05-14T03-08-22-123Z. Recover ISO and format locally.
  const m = ts.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-(\d{3})Z$/);
  if (!m) return ts;
  const iso = `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}.${m[7]}Z`;
  try {
    return new Date(iso).toLocaleString();
  } catch { return ts; }
}

function prettySize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}
