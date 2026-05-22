import type { JSX } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import type { Settings, FontFamily, Theme } from '../settings';
import { FONT_SIZE_OPTIONS, LINE_HEIGHT_OPTIONS, fontStack } from '../settings';
import { CITATION_FORMATS } from '../citation';
import { triggerEmbeddings, embeddingStatus } from '../api';
import { formatEmbedStatus, isEmbedRunning, type EmbedStatus } from '../embedding';
import { Icon } from './Icon';

const THEME_OPTIONS: { id: Theme; label: string; hint: string }[] = [
  { id: 'light',  label: '浅色',   hint: '' },
  { id: 'dark',   label: '深色',   hint: '' },
  { id: 'system', label: '跟随系统', hint: 'prefers-color-scheme' },
];

const FONT_PRESETS: { id: FontFamily; label: string; hint: string }[] = [
  { id: 'sans',  label: '苹方 / 无衬线', hint: '屏幕显示最稳，默认' },
  { id: 'serif', label: '宋体 / 衬线',   hint: '印刷感，长文阅读' },
  { id: 'mono',  label: '等宽',          hint: '代码 / 草稿感' },
];

const FONT_PREVIEW = 'The quick brown fox · 身体是被技术介导的对象';

type TabId = 'appearance' | 'editing' | 'citation' | 'vectors';
const TABS: { id: TabId; label: string }[] = [
  { id: 'appearance', label: '外观' },
  { id: 'editing',    label: '编辑' },
  { id: 'citation',   label: '引用' },
  { id: 'vectors',    label: '向量' },
];

interface Props {
  settings: Settings;
  onChange: (next: Settings) => void;
  onClose: () => void;
}

export function SettingsPanel({ settings, onChange, onClose }: Props) {
  const [tab, setTab] = useState<TabId>('appearance');
  const set = <K extends keyof Settings>(key: K, value: Settings[K]) =>
    onChange({ ...settings, [key]: value });

  return (
    <div class="fixed inset-0 bg-black/30 z-40" onClick={onClose}>
      <div
        class="absolute top-12 right-4 w-[520px] max-h-[calc(100vh-80px)] flex flex-col bg-surface border border-base rounded-2xl shadow-soft-lg overflow-hidden"
        onClick={e => e.stopPropagation()}
      >
        {/* Single header bar — the tabs double as the title (the active tab says
            where you are; a separate "设置" row would just be a redundant second
            chrome layer). Close button sits at the right. */}
        <div class="shrink-0 flex items-center justify-between pl-2 pr-2 border-b border-base">
          <div class="flex gap-0.5">
            {TABS.map(t => {
              const active = t.id === tab;
              return (
                <button
                  key={t.id}
                  onClick={() => setTab(t.id)}
                  class={`relative px-3 py-2.5 text-[12.5px] transition ${
                    active ? 'text-accent-text font-semibold' : 'text-secondary hover:text-primary'
                  }`}
                >
                  {t.label}
                  {active && <span class="absolute left-2.5 right-2.5 -bottom-px h-0.5 rounded bg-accent" />}
                </button>
              );
            })}
          </div>
          <button onClick={onClose} class="text-muted hover:text-secondary p-1.5 inline-flex items-center" title="关闭">
            <Icon name="x" size={13} />
          </button>
        </div>

        <div class="overflow-auto scrollbar-thin">
          {tab === 'appearance' && (
            <div class="p-5 space-y-7">
              <Group title="主题">
                <Segmented
                  value={settings.theme}
                  items={THEME_OPTIONS.map(t => ({ value: t.id, label: t.label, title: t.hint || undefined }))}
                  onChange={v => set('theme', v)}
                />
              </Group>

              <Group title="阅读排版">
                <div class="space-y-4">
                  <Field label="字体">
                    <RadioCards
                      name="fontFamily"
                      value={settings.fontFamily}
                      items={FONT_PRESETS.map(p => ({
                        value: p.id,
                        label: p.label,
                        hint: p.hint,
                        preview: FONT_PREVIEW,
                        labelStyle: { fontFamily: fontStack(p.id) },
                        previewStyle: { fontFamily: fontStack(p.id) },
                      }))}
                      onChange={v => set('fontFamily', v)}
                    />
                  </Field>
                  <Field label="字号">
                    <Segmented
                      value={settings.fontSize}
                      items={FONT_SIZE_OPTIONS.map(o => ({ value: o as number, label: String(o) }))}
                      onChange={v => set('fontSize', v)}
                    />
                  </Field>
                  <Field label="行距">
                    <Segmented
                      value={settings.lineHeight}
                      items={LINE_HEIGHT_OPTIONS.map(o => ({ value: o as number, label: o.toFixed(2) }))}
                      onChange={v => set('lineHeight', v)}
                    />
                  </Field>
                </div>
              </Group>
            </div>
          )}

          {tab === 'editing' && (
            <div class="p-5">
              <div class="flex items-start justify-between gap-3 px-3.5 py-3 rounded-xl border border-base">
                <div class="text-[12px] leading-snug min-w-0">
                  <div class="text-primary font-medium">允许编辑 LLM 生成的正文</div>
                  <div class="text-muted mt-0.5">
                    paper / book / author / topic / chapter 的 body 也进入编辑器。
                    默认关闭，避免误改 LLM 输出。下次 reprocess 仍会覆盖。
                  </div>
                </div>
                <Toggle on={settings.allowEditLLMBody} onChange={v => set('allowEditLLMBody', v)} />
              </div>
            </div>
          )}

          {tab === 'citation' && (
            <div class="p-5">
              <Field label="默认格式">
                <RadioCards
                  name="citationFormat"
                  value={settings.citationFormat}
                  items={CITATION_FORMATS.map(f => ({
                    value: f.id,
                    label: f.label,
                    hint: f.hint,
                    preview: f.example,
                  }))}
                  onChange={v => set('citationFormat', v)}
                />
                <div class="text-[11px] text-muted px-1 mt-2">在阅读时点按钮旁的 ▾ 可临时切换其他格式。</div>
              </Field>
            </div>
          )}

          {tab === 'vectors' && (
            <div class="p-5">
              <div class="rounded-xl border border-base p-4">
                <EmbeddingsRebuild />
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

/** Opt-in semantic-vector build, fully backgrounded. Triggering returns at once;
 *  the server runs the heavy model load + embed as a detached job. This panel
 *  polls status (so it also reflects a build the server auto-started on boot)
 *  and shows live progress instead of blocking on a multi-minute request. */
function EmbeddingsRebuild() {
  const [status, setStatus] = useState<EmbedStatus | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [pollKey, setPollKey] = useState(0);

  // Poll once on mount and after each trigger; re-arm while a build is running.
  // `following` is seeded from the status known when this effect started (set to
  // running right before the trigger bumps pollKey), so a transient fetch error
  // mid-build keeps retrying instead of freezing the panel with the button stuck
  // disabled until the user reopens settings.
  useEffect(() => {
    let alive = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let following = status != null && isEmbedRunning(status);
    const tick = async () => {
      try {
        const s = await embeddingStatus();
        if (!alive) return;
        setStatus(s);
        setErr(null);
        following = isEmbedRunning(s);
        if (following) timer = setTimeout(tick, 1500);
      } catch (e) {
        if (!alive) return;
        setErr(e instanceof Error ? e.message : String(e));
        if (following) timer = setTimeout(tick, 1500);
      }
    };
    tick();
    return () => {
      alive = false;
      if (timer) clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pollKey]);

  const running = status != null && isEmbedRunning(status);

  const run = async () => {
    if (running) return;
    setErr(null);
    try {
      const { status: s } = await triggerEmbeddings();
      setStatus(s);
      setPollKey(k => k + 1); // restart the poll loop to follow this build
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    }
  };

  const display = status ? formatEmbedStatus(status) : null;
  const toneClass =
    display?.tone === 'error'
      ? 'text-danger'
      : display?.tone === 'running'
        ? 'text-secondary'
        : 'text-muted';

  return (
    <div class="text-[12px] leading-snug">
      <div class="text-primary font-medium">语义向量（深度搜索）</div>
      <div class="text-muted mt-0.5 mb-2">
        普通"重建索引"快且不含向量。深度搜索需要单独构建向量，会下载 ~2.3GB 模型、
        可能数分钟；构建在后台进行，可关闭设置继续使用。与元数据索引分离，重建元数据不会清掉它。
      </div>
      <button
        onClick={run}
        disabled={running}
        class={`text-[12px] px-3 py-1.5 rounded-lg border transition ${
          running
            ? 'bg-surface text-muted border-base cursor-not-allowed'
            : 'bg-surface text-secondary border-strong hover:border-accent'
        }`}
      >
        {running ? '构建中…（后台运行，可关闭）' : '重建语义向量'}
      </button>
      {display && (
        <div class={`mt-2 text-[11px] ${toneClass}`}>{display.label}</div>
      )}
      {err && (
        <div class="mt-1 text-[11px] text-danger">{err}</div>
      )}
    </div>
  );
}

/** A labelled settings group: small uppercase caption + content. */
function Group({ title, children }: { title: string; children: JSX.Element | JSX.Element[] }) {
  return (
    <section>
      <div class="text-[10px] uppercase tracking-wider text-muted font-semibold mb-3">{title}</div>
      {children}
    </section>
  );
}

/** Two-column row: fixed-width label + control, so every setting's left edge lines up. */
function Field({ label, children }: { label: string; children: JSX.Element | JSX.Element[] }) {
  return (
    <div class="grid grid-cols-[64px_1fr] gap-3 items-start">
      <div class="text-[12px] text-secondary pt-1.5">{label}</div>
      <div class="min-w-0">{children}</div>
    </div>
  );
}

/** Segmented control for short enumerations (theme / size / line-height).
 *  Active segment lifts onto a surface tile; in dark mode it brightens to the
 *  hover token instead (surface would read as a pressed-in dent on the track). */
function Segmented<T extends string | number>({
  value, items, onChange,
}: {
  value: T;
  items: { value: T; label: string; title?: string }[];
  onChange: (v: T) => void;
}) {
  return (
    <div class="flex gap-1 bg-surface-2 p-[3px] rounded-[10px]">
      {items.map(it => {
        const on = it.value === value;
        return (
          <button
            key={String(it.value)}
            onClick={() => onChange(it.value)}
            title={it.title}
            class={`flex-1 rounded-lg py-1.5 text-[12px] tabular-nums transition ${
              on
                ? 'bg-surface dark:bg-hover text-primary font-medium shadow-soft-sm dark:shadow-none'
                : 'text-secondary hover:text-primary'
            }`}
          >
            {it.label}
          </button>
        );
      })}
    </div>
  );
}

/** Stacked single-select cards for options that carry a preview/description
 *  (font / citation format). Selection shows as an accent border + tint plus
 *  a custom radio dot; the real radio input stays for keyboard + a11y. */
function RadioCards<T extends string>({
  name, value, items, onChange,
}: {
  name: string;
  value: T;
  items: { value: T; label: string; hint?: string; preview?: string; labelStyle?: JSX.CSSProperties; previewStyle?: JSX.CSSProperties }[];
  onChange: (v: T) => void;
}) {
  return (
    <div class="space-y-1.5">
      {items.map(it => {
        const on = it.value === value;
        return (
          <label
            key={it.value}
            class={`flex items-start gap-2.5 px-3 py-2.5 rounded-[10px] border cursor-pointer transition ${
              on ? 'border-accent bg-accent-bg' : 'border-base hover:border-strong'
            }`}
          >
            <input type="radio" name={name} checked={on} onChange={() => onChange(it.value)} class="sr-only" />
            <RadioDot on={on} />
            <div class="flex-1 min-w-0">
              <div class="text-[12px] text-primary" style={it.labelStyle}>
                {it.label}
                {it.hint && <span class="text-muted text-[11px] ml-1">{it.hint}</span>}
              </div>
              {it.preview && (
                <div class="text-[12px] text-muted mt-0.5 truncate" style={it.previewStyle}>{it.preview}</div>
              )}
            </div>
          </label>
        );
      })}
    </div>
  );
}

function RadioDot({ on }: { on: boolean }) {
  return (
    <span
      class={`mt-0.5 shrink-0 w-3.5 h-3.5 rounded-full border-[1.5px] grid place-items-center ${
        on ? 'border-accent' : 'border-strong'
      }`}
      aria-hidden="true"
    >
      {on && <span class="w-1.5 h-1.5 rounded-full bg-accent" />}
    </span>
  );
}

/** Pill switch for booleans — replaces the bare checkbox. */
function Toggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return (
    <button
      role="switch"
      aria-checked={on}
      onClick={() => onChange(!on)}
      class={`relative shrink-0 w-9 h-[21px] rounded-full transition ${on ? 'bg-accent' : 'bg-strong'}`}
    >
      <span
        class={`absolute top-0.5 left-0.5 w-[17px] h-[17px] rounded-full bg-white shadow-soft-sm transition-transform ${
          on ? 'translate-x-[15px]' : ''
        }`}
      />
    </button>
  );
}
