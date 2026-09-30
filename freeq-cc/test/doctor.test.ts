import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { baseConfig, startChannel } from "./helpers.js";

const hook = (event: string) => ({
  [event]: [{ ...(event === "PreToolUse" ? { matcher: "" } : {}), hooks: [{ type: "mcp_tool", server: "freeq", tool: "freeq_hook", input: {} }] }],
});

beforeEach(() => {
  vi.stubGlobal("fetch", async (input: string | URL) => {
    const url = String(input);
    if (url.endsWith("/api/v1/health")) return new Response(JSON.stringify({ server_name: "test" }), { status: 200 });
    if (url.includes("/api/v1/actions")) return new Response(JSON.stringify({ tasks: [] }), { status: 200 });
    return new Response(null, { status: 404 });
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

/** The doctor's lines for this channel: everything after the kit's own. */
function ccLines(text: string): string[] {
  return text
    .split("\n")
    .filter((l) => /^\s+[✓⚠✗] (channel|hooks|permission relay):/.test(l))
    .map((l) => l.trim());
}

describe("/freeq:doctor", () => {
  it("reports the channel loaded, hooks missing, relay on", async () => {
    const h = await startChannel({ config: baseConfig() });
    const text = await h.prompt("doctor");
    expect(text).toContain("freeq doctor");
    expect(ccLines(text)).toEqual([
      "✓ channel: Claude Code loaded freeq as a channel",
      "⚠ hooks: missing for UserPromptSubmit, PreToolUse, Stop — add the mcp_tool hooks for freeq_hook (freeq-cc README)",
      "✓ permission relay: on — tool approvals go to did:plc:owner by DM",
    ]);
    await h.close();
  });

  it("finds the hooks in user settings or the project's, and says when the channel is not loaded", async () => {
    mkdirSync(join(homedir(), ".claude"), { recursive: true });
    writeFileSync(join(homedir(), ".claude", "settings.json"), JSON.stringify({ hooks: { ...hook("UserPromptSubmit"), ...hook("Stop") } }));
    const h = await startChannel({ config: baseConfig({ ownerDid: undefined }), experimental: {} });
    mkdirSync(join(h.cwd, ".claude"), { recursive: true });
    writeFileSync(join(h.cwd, ".claude", "settings.local.json"), JSON.stringify({ hooks: hook("PreToolUse") }));
    const text = await h.prompt("doctor");
    expect(ccLines(text)).toEqual([
      "⚠ channel: Claude Code did not declare claude/channel — start it with --dangerously-load-development-channels server:freeq",
      "✓ hooks: UserPromptSubmit, PreToolUse, Stop call freeq_hook",
      "⚠ permission relay: off — no owner configured (/freeq:login <did>)",
    ]);
    await h.close();
  });
});
