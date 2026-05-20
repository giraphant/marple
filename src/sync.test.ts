import { describe, it, expect } from 'vitest';
import {
  bumpVaultVersion, subscribeVaultChanges,
  VAULT_VERSION_KEY, SETTINGS_KEY,
} from './sync';

function fakeStorage() {
  const m = new Map<string, string>();
  return {
    getItem: (k: string) => (m.has(k) ? m.get(k)! : null),
    setItem: (k: string, v: string) => { m.set(k, v); },
  };
}

/** Build a storage-event-like object without depending on the StorageEvent ctor. */
function storageEvent(key: string | null): Event {
  const ev = new Event('storage') as Event & { key: string | null };
  ev.key = key;
  return ev;
}

describe('bumpVaultVersion', () => {
  it('writes a value to the vault-version key', () => {
    const store = fakeStorage();
    bumpVaultVersion(store);
    expect(store.getItem(VAULT_VERSION_KEY)).not.toBeNull();
  });

  it('writes a different value on consecutive calls (so the storage event always fires)', () => {
    const store = fakeStorage();
    bumpVaultVersion(store);
    const first = store.getItem(VAULT_VERSION_KEY);
    bumpVaultVersion(store);
    const second = store.getItem(VAULT_VERSION_KEY);
    expect(second).not.toBe(first);
  });
});

describe('subscribeVaultChanges', () => {
  it('calls onVaultChanged when the vault-version key changes', () => {
    const target = new EventTarget();
    let vault = 0;
    subscribeVaultChanges({ onVaultChanged: () => { vault++; } }, target);
    target.dispatchEvent(storageEvent(VAULT_VERSION_KEY));
    expect(vault).toBe(1);
  });

  it('calls onSettingsChanged when the settings key changes', () => {
    const target = new EventTarget();
    let settings = 0;
    subscribeVaultChanges({ onSettingsChanged: () => { settings++; } }, target);
    target.dispatchEvent(storageEvent(SETTINGS_KEY));
    expect(settings).toBe(1);
  });

  it('ignores unrelated storage keys', () => {
    const target = new EventTarget();
    let vault = 0, settings = 0;
    subscribeVaultChanges({
      onVaultChanged: () => { vault++; },
      onSettingsChanged: () => { settings++; },
    }, target);
    target.dispatchEvent(storageEvent('some-other-key'));
    expect(vault).toBe(0);
    expect(settings).toBe(0);
  });

  it('stops firing after unsubscribe', () => {
    const target = new EventTarget();
    let vault = 0;
    const unsubscribe = subscribeVaultChanges({ onVaultChanged: () => { vault++; } }, target);
    unsubscribe();
    target.dispatchEvent(storageEvent(VAULT_VERSION_KEY));
    expect(vault).toBe(0);
  });
});
