import { defineConfig } from 'vitest/config';

// Standalone test config — intentionally does NOT load vite.config.ts's
// preact / unplugin-icons plugins. The unit suites cover pure logic
// (session persistence, save-conflict decisions, cross-window signalling)
// and need only a DOM-ish environment for Storage / StorageEvent.
export default defineConfig({
  test: {
    environment: 'happy-dom',
    include: ['src/**/*.test.ts'],
    globals: false,
  },
});
