/**
 * The `/freeq` subcommands as MCP prompts. Claude Code lists each as
 * `/freeq:<name> (MCP)`, splits what is typed after it on whitespace and
 * fills the declared arguments in order, so every subcommand declares its
 * own. The runtime (`AgentRuntime.runCommand`) does the work.
 */

export interface CommandArg {
  name: string;
  description: string;
  required?: boolean;
}

export interface Command {
  name: string;
  description: string;
  args: CommandArg[];
}

/** `yes`, for a client that cannot show a confirmation (no MCP elicitation). */
const CONFIRM: CommandArg = {
  name: "confirm",
  description: "yes, to confirm without being asked (for a client that cannot ask)",
};

export const COMMANDS: Command[] = [
  { name: "status", description: "freeq: connection, identity, channels, trust summary", args: [] },
  {
    name: "doctor",
    description: "freeq: check identity, ownership, owner, config, server, connection, channels and this channel's setup",
    args: [],
  },
  {
    name: "login",
    description: "freeq: set the owner DID (your own) and connect",
    args: [{ name: "did", description: "your DID, did:plc:…", required: true }],
  },
  {
    name: "authorize",
    description: "freeq: add this installation as one of your agents; 'verify' asks the server for its verdict",
    args: [{ name: "step", description: "verify, or --sign-cert" }],
  },
  {
    name: "join",
    description: "freeq: join a channel (for this project)",
    args: [{ name: "channel", description: "#channel", required: true }],
  },
  {
    name: "leave",
    description: "freeq: leave a channel (for this project)",
    args: [{ name: "channel", description: "#channel", required: true }],
  },
  { name: "peers", description: "freeq: reachable agents, what they are working on, their tier", args: [] },
  {
    name: "mode",
    description: "freeq: how this agent listens in a channel",
    args: [
      { name: "channel", description: "#channel", required: true },
      { name: "mode", description: "silent | addressed | participant", required: true },
    ],
  },
  {
    name: "trust",
    description: "freeq: set a DID's trust tier",
    args: [
      { name: "did", description: "did:plc:… or did:key:…", required: true },
      { name: "tier", description: "observe | message | request | handoff | control", required: true },
      CONFIRM,
    ],
  },
  { name: "mute", description: "freeq: stay connected but answer and deliver nothing", args: [] },
  { name: "unmute", description: "freeq: undo mute", args: [] },
  { name: "on", description: "freeq: enable and connect", args: [] },
  { name: "off", description: "freeq: disconnect and disable", args: [] },
  { name: "handoffs", description: "freeq: handoffs offered to you and by you", args: [] },
  { name: "tasks", description: "freeq: what is assigned, queued, offered, or open nearby", args: [] },
  {
    name: "resume",
    description: "freeq: re-enter assigned work (all of it, capped, if no id)",
    args: [{ name: "id", description: "task id or its short prefix" }],
  },
  {
    name: "accept",
    description: "freeq: take a queued or offered task now",
    args: [{ name: "id", description: "task id or its short prefix", required: true }],
  },
  {
    name: "decline",
    description: "freeq: turn an offered task down, with a reason",
    args: [
      { name: "id", description: "task id or its short prefix", required: true },
      { name: "reason", description: "why" },
    ],
  },
  {
    name: "drop",
    description: "freeq: fail work in flight honestly instead of leaving it hanging",
    args: [
      { name: "id", description: "task id or its short prefix", required: true },
      { name: "reason", description: "why" },
    ],
  },
  {
    name: "progress",
    description: "freeq: report progress on a task by hand",
    args: [
      { name: "id", description: "task id or its short prefix", required: true },
      { name: "note", description: "what has been done", required: true },
    ],
  },
  {
    name: "withheld",
    description: "freeq: messages addressed to you that were not delivered; 'drop' discards them",
    args: [{ name: "action", description: "drop" }],
  },
  {
    name: "policy",
    description: "freeq: accept a channel's join policy",
    args: [
      { name: "channel", description: "#channel", required: true },
      { name: "verb", description: "accept" },
    ],
  },
  {
    name: "takeover",
    description: "freeq: take this project's connection from another session",
    args: [CONFIRM],
  },
  {
    name: "verbosity",
    description: "freeq: how much of this session's work is mirrored to freeq",
    args: [{ name: "level", description: "quiet | normal | more | off" }],
  },
  {
    name: "provenance",
    description: "freeq: the provenance tier",
    args: [{ name: "level", description: "silent | decisions | evidence | firehose" }],
  },
  { name: "help", description: "freeq: the subcommands", args: [] },
];

/** Subcommands whose trailing `confirm` argument may be `yes`. */
export const CONFIRMABLE = new Set(COMMANDS.filter((c) => c.args.includes(CONFIRM)).map((c) => c.name));

/**
 * The command line for the runtime, from a prompt's arguments in declared
 * order, and whether the person typed `yes` to confirm.
 */
export function commandLine(
  command: Command,
  args: Record<string, string | undefined> | undefined,
): { line: string; yes: boolean } {
  let yes = false;
  const words: string[] = [];
  for (const arg of command.args) {
    const value = args?.[arg.name]?.trim();
    if (!value) continue;
    if (arg === CONFIRM) {
      yes = value.toLowerCase() === "yes";
      continue;
    }
    words.push(value);
  }
  return { line: [command.name, ...words].join(" "), yes };
}
