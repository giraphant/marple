import type { Settings } from '../settings';

interface Props {
  settings: Settings;
  onChange: (next: Settings) => void;
  onClose: () => void;
}

export function SettingsPanel({ settings, onChange, onClose }: Props) {
  return (
    <div class="fixed inset-0 bg-black/30 z-40" onClick={onClose}>
      <div
        class="absolute top-12 right-4 w-[340px] bg-white border border-stone-200 rounded-md shadow-lg p-4"
        onClick={e => e.stopPropagation()}
      >
        <div class="flex items-center justify-between mb-3">
          <div class="text-[13px] font-semibold text-stone-800">设置</div>
          <button onClick={onClose} class="text-stone-400 hover:text-stone-700 text-base leading-none">✕</button>
        </div>
        <div class="space-y-3">
          <label class="flex items-start gap-2 cursor-pointer">
            <input
              type="checkbox"
              checked={settings.allowEditLLMBody}
              onChange={e => onChange({ ...settings, allowEditLLMBody: (e.target as HTMLInputElement).checked })}
              class="mt-0.5"
            />
            <div class="text-[12px] leading-snug">
              <div class="text-stone-800 font-medium">允许编辑 LLM 生成的正文</div>
              <div class="text-stone-500 mt-0.5">
                打开后，paper / book / author / topic / chapter 的 body 也会进入同一个 Markdown 编辑器。默认关闭以避免误改 LLM 输出；下次 reprocess 仍会覆盖。
              </div>
            </div>
          </label>
        </div>
      </div>
    </div>
  );
}
