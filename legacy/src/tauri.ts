import { invoke as tauriInvoke } from '@tauri-apps/api/core';

/** True only inside the Tauri webview (the v2 internals global is injected). */
export function isTauri(): boolean {
  return typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
}

/** Thin typed wrapper so call sites don't import the SDK directly. Tauri rejects
 *  with the bare String a Rust command returns on `Err`; normalize that to an
 *  `Error` here (once) so IPC failures match the fetch branch's error shape. */
export async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  try {
    return await tauriInvoke<T>(cmd, args);
  } catch (e) {
    throw e instanceof Error ? e : new Error(`IPC ${cmd} failed: ${e}`);
  }
}
