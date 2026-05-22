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

interface Props {
  settings: Settings;
  onChange: (next: Settings) => void;
  onClose: () => void;
}

const FONT_PRESETS: { id: FontFamily; label: string; hint: string }[] = [
  { id: 'sans',  label: '苹方 / 无衬线', hint: '屏幕显示最稳，默认' },
  { id: 'serif', label: '宋体 / 衬线',   hint: '印刷感，长文阅读' },
  { id: 'mono',  label: '等宽',          hint: '代码 / 草稿感' },
];

export function SettingsPanel({ settings, onChange, onClose }: Props) {
  const set = <K extends keyof Settings>(key: K, value: Settings[K]) =>
    onChange({ ...settings, [key]: value });

  return (
    <div class="fixed inset-0 bg-black/30 z-40" onClick={onClose}>
      <div
        class="absolute top-12 right-4 w-[520px] max-h-[calc(100vh-80px)] overflow-auto scrollbar-thin bg-surface border border-base rounded-2xl shadow-soft-lg"
        onClick={e => e.stopPropagation()}
      >
        <div class="flex items-center justify-between px-5 py-3 border-b border-base sticky top-0 bg-surface/95 backdrop-blur">
          <div class="text-[13px] font-semibold text-primary">设置</div>
          <button onClick={onClose} class="text-muted hover:text-secondary p-1 inline-flex items-center" title="关闭">
            <Icon name="x" size={13} />
          </button>
        </div>

        <Section title="外观">
          <Field label="主题">
            <div class="flex flex-wrap gap-1">
              {THEME_OPTIONS.map(t => {
                const active = settings.theme === t.id;
                return (
                  <button
                    key={t.id}
                    onClick={() => set('theme', t.id)}
                    class={`text-[12px] px-2.5 py-1 rounded border transition ${
                      active
                        ? 'bg-accent-bg text-accent-text border-accent'
                        : 'bg-surface text-secondary border-base hover:border-strong'
                    }`}
                    title={t.hint}
                  >{t.label}</button>
                );
              })}
            </div>
          </Field>

          <Field label="字体">
            <div class="space-y-1.5">
              {FONT_PRESETS.map(p => (
                <label key={p.id} class="flex items-start gap-2 cursor-pointer px-2 py-1.5 -mx-2 rounded hover:bg-page">
                  <input
                    type="radio"
                    name="fontFamily"
                    checked={settings.fontFamily === p.id}
                    onChange={() => set('fontFamily', p.id)}
                    class="mt-1"
                  />
                  <div class="flex-1 min-w-0">
                    <div class="text-[12px] text-primary" style={{ fontFamily: fontStack(p.id) }}>
                      {p.label} <span class="text-muted text-[11px] ml-1">{p.hint}</span>
                    </div>
                    <div
                      class="text-[12px] text-muted mt-0.5 truncate"
                      style={{ fontFamily: fontStack(p.id) }}
                      title="预览"
                    >
                      The quick brown fox · 身体是被技术介导的对象
                    </div>
                  </div>
                </label>
              ))}
            </div>
          </Field>

          <Field label="字号">
            <Slider
              value={settings.fontSize}
              options={FONT_SIZE_OPTIONS}
              suffix="px"
              onChange={v => set('fontSize', v)}
            />
          </Field>

          <Field label="行距">
            <Slider
              value={settings.lineHeight}
              options={LINE_HEIGHT_OPTIONS}
              format={v => v.toFixed(2)}
              onChange={v => set('lineHeight', v)}
            />
          </Field>
        </Section>

        <Section title="编辑">
          <label class="flex items-start gap-2 cursor-pointer px-2 py-1.5 -mx-2 rounded hover:bg-page">
            <input
              type="checkbox"
              checked={settings.allowEditLLMBody}
              onChange={e => set('allowEditLLMBody', (e.target as HTMLInputElement).checked)}
              class="mt-0.5"
            />
            <div class="text-[12px] leading-snug">
              <div class="text-primary font-medium">允许编辑 LLM 生成的正文</div>
              <div class="text-muted mt-0.5">
                paper / book / author / topic / chapter 的 body 也进入编辑器。
                默认关闭，避免误改 LLM 输出。下次 reprocess 仍会覆盖。
              </div>
            </div>
          </label>
        </Section>

        <Section title="引用">
          <Field label="默认格式">
            <div class="space-y-1">
              {CITATION_FORMATS.map(f => {
                const active = settings.citationFormat === f.id;
                return (
                  <label
                    key={f.id}
                    class={`flex items-start gap-2 cursor-pointer px-2 py-1.5 -mx-2 rounded ${active ? 'bg-page' : 'hover:bg-page'}`}
                  >
                    <input
                      type="radio"
                      name="citationFormat"
                      checked={active}
                      onChange={() => set('citationFormat', f.id)}
                      class="mt-1"
                    />
                    <div class="flex-1 min-w-0">
                      <div class="text-[12px] text-primary">
                        {f.label}
                        <span class="text-muted text-[11px] ml-1">{f.hint}</span>
                      </div>
                      <div class="text-[11px] text-muted mt-0.5 truncate">
                        {f.example}
                      </div>
                    </div>
                  </label>
                );
              })}
              <div class="text-[11px] text-muted px-2 mt-1">在阅读时点按钮旁的 ▾ 可临时切换其他格式。</div>
            </div>
          </Field>
        </Section>

        <Section title="高级">
          <EmbeddingsRebuild />
        </Section>
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
        class={`text-[12px] px-2.5 py-1 rounded border transition ${
          running
            ? 'bg-surface text-muted border-base cursor-not-allowed'
            : 'bg-surface text-secondary border-base hover:border-strong'
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

function Section({ title, children }: { title: string; children: JSX.Element | JSX.Element[] }) {
  return (
    <section class="px-5 py-4 border-b border-base last:border-b-0">
      <div class="text-[10px] uppercase tracking-wider text-muted font-semibold mb-3">{title}</div>
      <div class="space-y-4">{children}</div>
    </section>
  );
}

function Field({ label, children }: { label: string; children: JSX.Element | JSX.Element[] }) {
  return (
    <div class="grid grid-cols-[72px_1fr] gap-3 items-start">
      <div class="text-[12px] text-secondary pt-1">{label}</div>
      <div class="min-w-0">{children}</div>
    </div>
  );
}

function Slider<T extends number>({
  value, options, onChange, format, suffix,
}: {
  value: T;
  options: readonly T[];
  onChange: (v: T) => void;
  format?: (v: T) => string;
  suffix?: string;
}) {
  return (
    <div class="flex flex-wrap gap-1">
      {options.map(opt => {
        const active = opt === value;
        const display = format ? format(opt) : String(opt);
        return (
          <button
            key={opt}
            onClick={() => onChange(opt)}
            class={`text-[12px] px-2.5 py-1 rounded border tabular-nums transition ${
              active
                ? 'bg-accent-bg text-accent-text border-accent'
                : 'bg-surface text-secondary border-base hover:border-strong'
            }`}
          >
            {display}{suffix && <span class="opacity-70 ml-0.5">{suffix}</span>}
          </button>
        );
      })}
    </div>
  );
}
