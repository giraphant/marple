/** Map `items` through async `fn` with at most `limit` in flight at once,
 *  preserving input order in the result. Unlike `Promise.all(items.map(fn))` it
 *  never floods the browser connection pool, so a large vault sync can't stall
 *  user-initiated requests (QUA-72). */
export async function mapPool<T, R>(
  items: T[],
  limit: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  const worker = async () => {
    while (true) {
      const i = next++;
      if (i >= items.length) return;
      results[i] = await fn(items[i]);
    }
  };
  const workers = Math.max(1, Math.min(limit, items.length));
  await Promise.all(Array.from({ length: workers }, worker));
  return results;
}
