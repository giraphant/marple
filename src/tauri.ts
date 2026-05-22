import { invoke as tauriInvoke } from '@tauri-apps/api/core';

/** True only inside the Tauri webview (the v2 internals global is injected). */
export function isTauri(): boolean {
  return typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
}

/** Thin typed wrapper so call sites don't import the SDK directly. */
export function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  return tauriInvoke<T>(cmd, args);
}
