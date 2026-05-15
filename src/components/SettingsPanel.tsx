import type { JSX } from 'preact';
import type { Settings, FontFamily, Theme } from '../settings';
import { FONT_SIZE_OPTIONS, LINE_HEIGHT_OPTIONS, fontStack } from '../settings';
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
        class="absolute top-12 right-4 w-[520px] max-h-[calc(100vh-80px)] overflow-auto scrollbar-thin bg-surface border border-base rounded-lg shadow-xl"
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
                        ? 'bg-inverse text-inverse-fg border-primary'
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
      </div>
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
                ? 'bg-inverse text-inverse-fg border-primary'
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
