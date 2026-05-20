import type { StorageLike } from './session';
import { SETTINGS_KEY } from './settings';

export { SETTINGS_KEY };

// Cross-window signalling via the standard `storage` event. A window bumps a
// version key after any successful vault write; OTHER windows receive the
// storage event (it never fires in the writer itself, so no echo loop) and
// re-read the now-authoritative server index. We ship only a *signal*, never
// entry payloads — each refetch is a full consistent snapshot, so there are no
// message-ordering / merge races.
export const VAULT_VERSION_KEY = 'qua-reader-vault-version';

let counter = 0;

/** Mark that this window changed the vault, nudging other windows to refetch. */
export function bumpVaultVersion(local: StorageLike = window.localStorage): void {
  try { local.setItem(VAULT_VERSION_KEY, `${Date.now()}-${counter++}`); } catch {}
}

export interface VaultChangeHandlers {
  onVaultChanged?: () => void;
  onSettingsChanged?: () => void;
}

/** Subscribe to cross-window vault/settings changes. Returns an unsubscribe fn. */
export function subscribeVaultChanges(
  handlers: VaultChangeHandlers,
  target: EventTarget = window,
): () => void {
  const listener = (e: Event) => {
    const key = (e as StorageEvent).key;
    if (key === VAULT_VERSION_KEY) handlers.onVaultChanged?.();
    else if (key === SETTINGS_KEY) handlers.onSettingsChanged?.();
  };
  target.addEventListener('storage', listener);
  return () => target.removeEventListener('storage', listener);
}
