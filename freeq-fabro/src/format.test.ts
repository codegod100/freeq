import { describe, expect, it } from "vitest";
import { formatHook, runLink } from "./format.js";

const base = { run_id: "01KV730C7B", workflow_name: "bug-hunt" };

describe("formatHook", () => {
  it("announces run start with a web link when configured", () => {
    expect(formatHook({ ...base, event: "run_start" }, { webUrl: "https://f.example/" }))
      .toBe("fabro: bug-hunt started — https://f.example/runs/01KV730C7B");
  });

  it("falls back to the inspect command without a web URL", () => {
    expect(formatHook({ ...base, event: "run_start" }))
      .toBe("fabro: bug-hunt started — fabro inspect 01KV730C7B");
  });

  it("links the PR on completion when one was found", () => {
    expect(formatHook({ ...base, event: "run_complete" }, { prUrl: "https://github.com/x/y/pull/9" }))
      .toBe("fabro: bug-hunt finished green — PR https://github.com/x/y/pull/9");
  });

  it("says so when a completed run opened no PR", () => {
    expect(formatHook({ ...base, event: "run_complete" }))
      .toBe("fabro: bug-hunt finished (no PR) — fabro inspect 01KV730C7B");
  });

  it("flattens and truncates long failure reasons to one line", () => {
    const line = formatHook({ ...base, event: "run_failed", failure_reason: "boom\n".repeat(200) })!;
    expect(line).not.toContain("\n");
    expect(line).toMatch(/^fabro: bug-hunt FAILED: boom boom .*… — fabro inspect 01KV730C7B$/);
  });

  it("names the gate a run is waiting on", () => {
    expect(formatHook({ ...base, workflow_name: "feature", event: "stage_start", node_id: "approve", node_label: "Approve plan?" }))
      .toBe('fabro: feature is waiting for your approval at "Approve plan?" — fabro inspect 01KV730C7B');
  });

  it("ignores events it has no message for", () => {
    expect(formatHook({ ...base, event: "checkpoint_saved" })).toBeNull();
    expect(formatHook({})).toBeNull();
  });
});

describe("runLink", () => {
  it("is empty without a run id", () => {
    expect(runLink(undefined, "https://f.example")).toBe("");
  });
});
