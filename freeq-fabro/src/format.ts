// Fabro hook context → one IRC line.
//
// Fabro POSTs the event context as JSON (docs.fabro.sh/agents/hooks, "Hook
// context"). Null fields are omitted, and fields vary by event, so every
// field here is optional and unknown events format to null (not posted).

export interface HookContext {
  event?: string;
  run_id?: string;
  workflow_name?: string;
  node_id?: string;
  node_label?: string;
  failure_reason?: string;
}

export interface FormatOptions {
  /** Public base URL of the Fabro web UI, e.g. https://fabro-freeq.boxd.sh.
   *  When set, messages link to the run. */
  webUrl?: string;
  /** PR opened by the run, when known (run_complete only). */
  prUrl?: string;
}

const MAX_REASON = 240;

export function runLink(runId: string | undefined, webUrl?: string): string {
  if (!runId) return "";
  if (webUrl) return `${webUrl.replace(/\/+$/, "")}/runs/${runId}`;
  return `fabro inspect ${runId}`;
}

function oneLine(s: string, max: number): string {
  const flat = s.replace(/\s+/g, " ").trim();
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}

export function formatHook(ctx: HookContext, opts: FormatOptions = {}): string | null {
  const wf = ctx.workflow_name ?? "workflow";
  const link = runLink(ctx.run_id, opts.webUrl);
  const tail = link ? ` — ${link}` : "";

  switch (ctx.event) {
    case "run_start":
      return `fabro: ${wf} started${tail}`;
    case "run_complete":
      return opts.prUrl
        ? `fabro: ${wf} finished green — PR ${opts.prUrl}`
        : `fabro: ${wf} finished (no PR)${tail}`;
    case "run_failed": {
      const why = ctx.failure_reason ? `: ${oneLine(ctx.failure_reason, MAX_REASON)}` : "";
      return `fabro: ${wf} FAILED${why}${tail}`;
    }
    case "stage_start": {
      // Only human-gate stages are routed here (hook matcher "^approve").
      const gate = ctx.node_label ?? ctx.node_id ?? "a gate";
      return `fabro: ${wf} is waiting for your approval at "${gate}"${tail}`;
    }
    default:
      return null;
  }
}
