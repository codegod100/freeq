/**
 * What freeq-cc checks about its own setup for `/freeq:doctor`, after the
 * kit's common checks: whether Claude Code's settings install the three
 * `mcp_tool` hooks that call `freeq_hook`.
 */
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

/** The hook events freeq-cc needs, in the order the README lists them. */
export const HOOK_EVENTS = ["UserPromptSubmit", "PreToolUse", "Stop"] as const;

interface HookEntry {
  type?: string;
  server?: string;
  tool?: string;
}

/** The settings files Claude Code reads hooks from: user, then project. */
export function settingsFiles(projectDir: string): string[] {
  return [
    join(homedir(), ".claude", "settings.json"),
    join(projectDir, ".claude", "settings.json"),
    join(projectDir, ".claude", "settings.local.json"),
  ];
}

/** The hook events, among `HOOK_EVENTS`, that some settings file points at `server`'s `tool`. */
export async function installedHooks(files: string[], server: string, tool: string): Promise<Set<string>> {
  const found = new Set<string>();
  for (const file of files) {
    let settings: { hooks?: Record<string, Array<{ hooks?: HookEntry[] }>> };
    try {
      settings = JSON.parse(await readFile(file, "utf8"));
    } catch {
      continue; // absent or unreadable: nothing installed there
    }
    for (const event of HOOK_EVENTS) {
      const groups = settings.hooks?.[event];
      if (!Array.isArray(groups)) continue;
      const hit = groups.some((g) =>
        (g.hooks ?? []).some((h) => h.type === "mcp_tool" && h.server === server && h.tool === tool),
      );
      if (hit) found.add(event);
    }
  }
  return found;
}
