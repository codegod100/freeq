import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // HOME points at a scratch directory before any module reads it: the
    // kit looks for identities under ~/.freeq, read once at import.
    setupFiles: ["./test/setup.ts"],
  },
});
