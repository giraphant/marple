import { useMemo } from 'preact/hooks';
import type { Entry } from '../types';

interface Props {
  entries: Entry[];
}

const CELL = 12;   // px square
const GAP = 3;     // px between cells
const WEEKS = 53;  // columns shown
const DAYS = 7;    // rows: Sun..Sat

const INTENSITY_CLASS = [
  'bg-surface-2 border border-base',
  'bg-accent/20',
  'bg-accent/40',
  'bg-accent/70',
  'bg-accent',
];

function bucket(n: number): number {
  if (n <= 0) return 0;
  if (n <= 2)  return 1;
  if (n <= 5)  return 2;
  if (n <= 15) return 3;
  return 4;
}

function pad(n: number) { return n < 10 ? `0${n}` : String(n); }
function isoDay(d: Date) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function startOfDay(d: Date) {
  const x = new Date(d);
  x.setHours(0, 0, 0, 0);
  return x;
}

const MONTH_LABELS = ['1月', '2月', '3月', '4月', '5月', '6月', '7月', '8月', '9月', '10月', '11月', '12月'];
const DAY_LABELS = ['日', '一', '二', '三', '四', '五', '六'];

export function ActivityView({ entries }: Props) {
  const { byDay, total, maxDay, gridStart } = useMemo(() => {
    const m = new Map<string, number>();
    for (const e of entries) {
      if (!e.mtime) continue;
      const d = new Date(e.mtime);
      const key = isoDay(d);
      m.set(key, (m.get(key) ?? 0) + 1);
    }
    // Grid: ends on today's column; starts 52 weeks back, padded to Sunday.
    const today = startOfDay(new Date());
    const endCol = new Date(today);
    // Find Sunday of *next* week (so today's column is the last one)
    const daysToSat = (6 - today.getDay()); // days until upcoming Saturday
    endCol.setDate(endCol.getDate() + daysToSat); // end of current week (Sat)
    const start = new Date(endCol);
    start.setDate(start.getDate() - (WEEKS * 7 - 1)); // 53 weeks back, Sunday
    // Stats
    let mDay = '';
    let mCount = 0;
    let t = 0;
    for (const [k, v] of m) {
      t += v;
      if (v > mCount) { mCount = v; mDay = k; }
    }
    return { byDay: m, total: t, maxDay: mDay ? { day: mDay, n: mCount } : null, gridStart: start };
  }, [entries]);

  // Pre-compute month label positions
  const monthMarks = useMemo(() => {
    const marks: { col: number; label: string }[] = [];
    let lastMonth = -1;
    for (let col = 0; col < WEEKS; col++) {
      const d = new Date(gridStart);
      d.setDate(d.getDate() + col * 7);
      const m = d.getMonth();
      if (m !== lastMonth) {
        marks.push({ col, label: MONTH_LABELS[m] });
        lastMonth = m;
      }
    }
    return marks;
  }, [gridStart]);

  const today = startOfDay(new Date());

  return (
    <div class="flex-1 flex flex-col min-h-0">
      <header class="bg-surface/95 backdrop-blur border-b border-base sticky top-0 z-10">
        <div class="px-6 py-3 flex items-baseline gap-4">
          <div class="text-[18px] font-semibold tracking-tight text-primary">活动</div>
          <div class="text-[11px] text-muted">
            过去一年 vault 文件变动 · 共 <span class="text-primary tabular-nums">{total}</span> 次
          </div>
          {maxDay && (
            <div class="text-[11px] text-muted tabular-nums">
              最忙：{maxDay.day} · {maxDay.n}
            </div>
          )}
        </div>
      </header>

      <main class="flex-1 overflow-auto scrollbar-thin px-6 py-6">
        <div class="inline-block">
          {/* month labels */}
          <div class="relative ml-7 mb-1" style={{ width: WEEKS * (CELL + GAP) - GAP, height: 14 }}>
            {monthMarks.map(m => (
              <div
                key={`${m.col}-${m.label}`}
                class="absolute text-[10px] text-muted"
                style={{ left: m.col * (CELL + GAP) }}
              >{m.label}</div>
            ))}
          </div>

          <div class="flex items-start gap-1">
            {/* day-of-week labels */}
            <div class="flex flex-col" style={{ rowGap: GAP, marginRight: 4 }}>
              {DAY_LABELS.map((d, i) => (
                <div
                  key={d}
                  class="text-[10px] text-muted leading-none flex items-center"
                  style={{
                    height: CELL,
                    visibility: i % 2 === 1 ? 'visible' : 'hidden',
                  }}
                >{d}</div>
              ))}
            </div>

            {/* grid */}
            <div class="flex" style={{ columnGap: GAP }}>
              {Array.from({ length: WEEKS }, (_, col) => (
                <div key={col} class="flex flex-col" style={{ rowGap: GAP }}>
                  {Array.from({ length: DAYS }, (_, row) => {
                    const d = new Date(gridStart);
                    d.setDate(d.getDate() + col * 7 + row);
                    const isFuture = d > today;
                    const key = isoDay(d);
                    const n = byDay.get(key) ?? 0;
                    const cls = isFuture ? 'invisible' : INTENSITY_CLASS[bucket(n)];
                    return (
                      <div
                        key={row}
                        class={`${cls} rounded-[2px]`}
                        style={{ width: CELL, height: CELL }}
                        title={isFuture ? '' : `${key} · ${n} 个文件变动`}
                      />
                    );
                  })}
                </div>
              ))}
            </div>
          </div>

          {/* legend */}
          <div class="flex items-center gap-1.5 mt-4 text-[10px] text-muted ml-7">
            <span>少</span>
            {INTENSITY_CLASS.map((cls, i) => (
              <span key={i} class={`${cls} rounded-[2px]`} style={{ width: CELL, height: CELL }} />
            ))}
            <span>多</span>
          </div>
        </div>
      </main>
    </div>
  );
}
