import { describe, it, expect } from 'vitest';
import { mapPool } from './map-pool';

describe('mapPool (QUA-72 sync concurrency bound)', () => {
  it('preserves input order in the result', async () => {
    const out = await mapPool([1, 2, 3, 4, 5], 2, async n => n * 10);
    expect(out).toEqual([10, 20, 30, 40, 50]);
  });

  it('never exceeds the concurrency limit', async () => {
    let inFlight = 0;
    let peak = 0;
    const items = Array.from({ length: 50 }, (_, i) => i);
    await mapPool(items, 5, async () => {
      inFlight++;
      peak = Math.max(peak, inFlight);
      await new Promise(r => setTimeout(r, 1));
      inFlight--;
    });
    expect(peak).toBeLessThanOrEqual(5);
    expect(peak).toBeGreaterThan(1); // it does run things in parallel
  });

  it('handles an empty list and a limit larger than the list', async () => {
    expect(await mapPool([], 5, async (x: number) => x)).toEqual([]);
    expect(await mapPool([7], 99, async n => n + 1)).toEqual([8]);
  });
});
