/**
 * A fake pi host and a fake bot-kit bot, for driving `extensions/freeq.ts`
 * with no pi process and no socket.
 *
 * The extension is the pi adapter plus most of freeq-pi's runtime, and it
 * had no tests. These fakes let a test load it the way pi does (call its
 * default export with an `ExtensionAPI`), fire pi's lifecycle events, run
 * the `freeq` tool and `/freeq` command, and drive the server side through
 * the bot's events, then read back what reached the model, the person and
 * the wire.
 *
 * Two modules are mocked for every test file that imports this one:
 * `@earendil-works/pi-coding-agent` (only `getAgentDir` and
 * `CONFIG_DIR_NAME` are used at run time) and `@freeq/bot-kit`, whose
 * `FreeqBot.create` returns the current fake bot (the extension never passes
 * `botFactory` to the connection, so the bot is swapped at the module).
 *
 * The tests here import nothing from `src/`: they pin the extension's
 * behaviour from the outside, so the modules underneath can move without a
 * pinning test changing.
 */

import { vi } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Real timer functions, captured before any test installs fake timers, so
// `settle()` can let promise chains run while the clock is frozen.
const realSetImmediate = globalThis.setImmediate;

/** Shared, mutable state the module mocks read from. */
const state: { agentDir: string; bot: FakeBot | undefined } = {
  agentDir: "",
  bot: undefined,
};

// HOME decides where the extension looks for ~/.freeq (read once, when the
// extension module is first imported), so it points at a scratch directory
// before anything imports it.
const home = mkdtempSync(join(tmpdir(), "freeq-pi-pin-"));
process.env.HOME = home;

vi.mock("@earendil-works/pi-coding-agent", () => ({
  CONFIG_DIR_NAME: ".pi",
  getAgentDir: () => state.agentDir,
}));

vi.mock("@freeq/bot-kit", async (orig) => ({
  ...(await orig<object>()),
  FreeqBot: {
    create: async (opts: BotCreateOptions) => {
      const bot = state.bot;
      if (!bot) throw new Error("fake-pi: no fake bot installed");
      bot.created.push(opts);
      bot.nickValue = opts.nick;
      bot.createOpts = opts;
      return bot;
    },
  },
}));

export interface BotCreateOptions {
  name: string;
  ownerDid: string;
  nick: string;
  url: string;
  root?: string;
  channels?: string[];
  initialStatus: string;
  mention: { matcher: (text: string, nick: string) => string | null };
  [k: string]: unknown;
}

export interface WireItem {
  kind: "join" | "raw" | "message" | "tagmsg" | "act";
  target: string;
  payload: unknown;
}

type Handler = (...a: unknown[]) => unknown;

/**
 * A bot-kit bot as far as `src/connection.ts` uses one. Everything the
 * extension puts on the wire lands in `sent`, in order.
 */
export class FakeBot {
  handlers = new Map<string, Handler[]>();
  sent: WireItem[] = [];
  states: Array<{ state: string; status?: string; task?: string }> = [];
  stopped: string[] = [];
  created: BotCreateOptions[] = [];
  createOpts: BotCreateOptions | undefined;
  nickValue: string | null = null;
  identity = { did: "did:key:zSelf" };
  provenance: { verified: boolean; reason: string; text: string } | null = null;
  /** Channels where bot-kit's mention cooldown is running. */
  cooling = new Set<string>();
  /** Next act event id to hand back; defaults to a fixed ULID-shaped id. */
  nextActIds: string[] = [];
  /** When set, `sendAct` rejects with this message. */
  failAct: string | undefined;

  client = ((self: FakeBot) => ({
    get nick(): string | null {
      return self.nickValue;
    },
    join: (channel: string) => this.sent.push({ kind: "join", target: channel, payload: null }),
    raw: (line: string) => this.sent.push({ kind: "raw", target: "", payload: line }),
    sendMessage: (target: string, text: string) =>
      this.sent.push({ kind: "message", target, payload: text }),
    sendTagmsg: (target: string, tags: Record<string, string>) =>
      this.sent.push({ kind: "tagmsg", target, payload: tags }),
    sendAct: async (target: string, tags: Record<string, string>, opts?: unknown) => {
      if (this.failAct) throw new Error(this.failAct);
      this.sent.push({ kind: "act", target, payload: tags });
      void opts;
      return this.nextActIds.shift() ?? "01JTASK0000000000000000000";
    },
    signing: { getPublicKey: () => "fake-pubkey" },
  }))(this);

  on(event: string, handler: Handler): this {
    this.handlers.set(event, [...(this.handlers.get(event) ?? []), handler]);
    return this;
  }
  async start(): Promise<this> {
    return this;
  }
  async stop(reason?: string): Promise<this> {
    this.stopped.push(reason ?? "");
    return this;
  }
  setState(state: string, status?: string, task?: string): void {
    this.states.push({ state, status, task });
  }
  /** bot-kit's mention check: the extension's matcher, plus a cooldown. */
  checkMention(channel: string, text: string): { kind: string; stripped?: string } {
    const stripped = this.createOpts?.mention.matcher(text, this.nickValue ?? "") ?? null;
    if (stripped === null) return { kind: "ignore" };
    if (this.cooling.has(channel.toLowerCase())) return { kind: "cooldown" };
    return { kind: "respond", stripped };
  }
  async resolveSenderDid(msg: { tags?: Record<string, string> }): Promise<string | null> {
    return msg.tags?.account ?? null;
  }
  /** Drive an event the way the server would. */
  emit(event: string, ...args: unknown[]): void {
    for (const h of this.handlers.get(event) ?? []) h(...args);
  }

  /** Wire items of one kind. */
  of(kind: WireItem["kind"]): WireItem[] {
    return this.sent.filter((s) => s.kind === kind);
  }
  /** PRIVMSGs as `target text` strings, the easiest shape to assert on. */
  messages(): string[] {
    return this.of("message").map((m) => `${m.target} ${String(m.payload)}`);
  }
}

/** One `pi.sendMessage` call: what reached the model, and how. */
export interface Delivery {
  msg: {
    customType: string;
    content: string;
    display: boolean;
    details: Record<string, unknown>;
  };
  opts: { deliverAs?: string; triggerTurn?: boolean };
}

export interface Notice {
  text: string;
  level: string;
}

export interface StartOptions {
  /** Written as `<agentDir>/freeq.json`. Omit for a fresh install. */
  config?: Record<string, unknown>;
  /** Project directory name; also the project name (no git repo). */
  project?: string;
  hasUI?: boolean;
  idle?: boolean;
  modelId?: string;
  /** Pre-existing session entries, for the task journal. */
  entries?: Array<{ type: string; customType?: string; data?: unknown }>;
  /** Fire `session_start` (default true). */
  start?: boolean;
}

/** The owner DID every default config uses. */
export const OWNER = "did:plc:owner";

/** A config that connects on session start in project `proj`. */
export function baseConfig(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    ownerDid: OWNER,
    server: "ws://test.invalid/irc",
    install: "test1234",
    channels: ["#work"],
    projects: { proj: { channels: ["#work"] } },
    trust: {},
    ...over,
  };
}

/** Let fire-and-forget async work in the extension run to completion. */
export async function settle(rounds = 20): Promise<void> {
  for (let i = 0; i < rounds; i++) await new Promise((r) => realSetImmediate(r));
}

let loaded: ((pi: unknown) => void) | undefined;

/**
 * Load a fresh extension instance against a fake pi, with its own agent
 * directory and project directory, and (by default) fire `session_start`.
 */
export async function startPi(opts: StartOptions = {}) {
  const root = mkdtempSync(join(tmpdir(), "freeq-pi-pin-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, opts.project ?? "proj");
  mkdirSync(agentDir, { recursive: true });
  mkdirSync(cwd, { recursive: true });
  if (opts.config) writeFileSync(join(agentDir, "freeq.json"), JSON.stringify(opts.config));
  state.agentDir = agentDir;
  const fakeBot = new FakeBot();
  state.bot = fakeBot;

  const handlers = new Map<string, Handler[]>();
  const tools = new Map<string, any>();
  const commands = new Map<string, any>();
  const messageRenderers = new Map<string, any>();
  const entryRenderers = new Map<string, any>();
  const entries: Array<{ type: string; customType: string; data: unknown }> = [];
  const delivered: Delivery[] = [];
  const notices: Notice[] = [];
  const confirms: Array<{ title: string; body: string }> = [];
  /** Answers for the next `ctx.ui.confirm` calls, in order; default false. */
  const confirmAnswers: boolean[] = [];
  const widgets = new Map<string, unknown>();
  const statuses = new Map<string, string | undefined>();
  const titles: string[] = [];
  const autocomplete: Array<(current: any) => any> = [];
  /** When set, `pi.sendMessage` throws this. */
  let sendFails: string | undefined;

  const pi = {
    on: (event: string, h: Handler) => handlers.set(event, [...(handlers.get(event) ?? []), h]),
    registerTool: (t: any) => tools.set(t.name, t),
    registerCommand: (name: string, c: any) => commands.set(name, c),
    registerMessageRenderer: (type: string, r: any) => messageRenderers.set(type, r),
    registerEntryRenderer: (type: string, r: any) => entryRenderers.set(type, r),
    appendEntry: (customType: string, data: unknown) =>
      entries.push({ type: "custom", customType, data }),
    sendMessage: (msg: any, o: any) => {
      if (sendFails) throw new Error(sendFails);
      delivered.push({ msg, opts: o });
    },
  };

  let idle = opts.idle ?? true;
  let modelId = opts.modelId ?? "test-model";
  const ctx = {
    cwd,
    get model() {
      return { id: modelId };
    },
    hasUI: opts.hasUI ?? false,
    ui: {
      notify: (text: string, level = "info") => notices.push({ text, level }),
      confirm: async (title: string, body: string) => {
        confirms.push({ title, body });
        return confirmAnswers.shift() ?? false;
      },
      setWidget: (key: string, content: unknown) => widgets.set(key, content),
      setStatus: (key: string, text: string | undefined) => statuses.set(key, text),
      setTitle: (t: string) => titles.push(t),
      addAutocompleteProvider: (f: (current: any) => any) => autocomplete.push(f),
    },
    isIdle: () => idle,
    isProjectTrusted: () => false,
    sessionManager: {
      getEntries: () => [...(opts.entries ?? []), ...entries],
    },
  };

  if (!loaded) loaded = (await import("../extensions/freeq.js")).default as (pi: unknown) => void;
  loaded(pi);

  async function fire(event: string, payload: unknown = {}): Promise<void> {
    for (const h of handlers.get(event) ?? []) await h(payload, ctx);
    await settle();
  }

  const h = {
    root,
    agentDir,
    cwd,
    pi,
    ctx,
    bot: fakeBot,
    handlers,
    tools,
    commands,
    messageRenderers,
    entryRenderers,
    entries,
    delivered,
    notices,
    confirms,
    confirmAnswers,
    widgets,
    statuses,
    titles,
    autocomplete,
    fire,
    setIdle(v: boolean) {
      idle = v;
    },
    setModel(id: string) {
      modelId = id;
    },
    failSend(message: string | undefined) {
      sendFails = message;
    },
    /** Run `/freeq <args>`. */
    async command(args: string): Promise<void> {
      await commands.get("freeq").handler(args, ctx);
      await settle();
    },
    /** Run the `freeq` tool and return its text. */
    async tool(params: Record<string, unknown>): Promise<string> {
      const r = await tools.get("freeq").execute("call-1", params, undefined, undefined, ctx);
      await settle();
      return r.content.map((c: { text: string }) => c.text).join("\n");
    },
    /** A direct message from `from`, whose server-resolved DID is `did`. */
    async dm(from: string, did: string | null, text: string): Promise<void> {
      fakeBot.emit("message", from, { from, text, isSelf: false, tags: did ? { account: did } : {} });
      await settle();
    },
    /** A channel message. */
    async say(channel: string, from: string, did: string | null, text: string): Promise<void> {
      fakeBot.emit("message", channel, {
        from,
        text,
        isSelf: false,
        tags: did ? { account: did } : {},
      });
      await settle();
    },
    /** Notices whose text contains `s`. */
    noticesWith(s: string): Notice[] {
      return notices.filter((n) => n.text.includes(s));
    },
    /** The last notice. */
    lastNotice(): Notice | undefined {
      return notices[notices.length - 1];
    },
    /** A pi turn: turn_start, then turn_end with this text (and tool calls). */
    async turn(text: string, opts2: { toolCalls?: boolean } = {}): Promise<void> {
      await fire("turn_start");
      const content: unknown[] = [];
      if (text) content.push({ type: "text", text });
      if (opts2.toolCalls) content.push({ type: "toolCall", id: "t1", name: "bash", arguments: {} });
      await fire("turn_end", { message: { role: "assistant", content } });
    },
    async shutdown(): Promise<void> {
      await fire("session_shutdown");
    },
  };

  if (opts.start ?? true) await fire("session_start");
  return h;
}

export type Pi = Awaited<ReturnType<typeof startPi>>;
