/**
 * The freeq side of an agent harness: one agent's session on freeq.
 *
 * Hard rules (carried over from freeq-pi, where this code began):
 *   - remote input never invokes local tools directly: it becomes a framed,
 *     tier-gated message, and the local agent decides what to do
 *   - content reaches the model in exactly ONE place (`deliver`), gated by
 *     `decideInbound` — no other code path may inject remote input
 *   - no filesystem paths in advertised presence
 *   - connection failure degrades to offline, never breaks the session
 *
 * The harness (`harness.ts`) supplies delivery into the model, notices and
 * confirmations, the journal, and what the session is doing. The harness
 * calls the `on…` methods here from its own events.
 */

import { existsSync } from "node:fs";
import { access as fsAccess } from "node:fs/promises";
import { homedir } from "node:os";
import { join as joinPath } from "node:path";

import type { ActEventPayload } from "@freeq/sdk";
import {
  loadConfig,
  saveConfig,
  channelsForProject,
  modeFor,
  tierFor,
  tierAtLeast,
  type FreeqConfig,
} from "./config.js";
import { deriveInstallSlug, isDid, resolveBotName } from "./identity.js";
import { creatorKeyPath } from "./owner-key.js";
import { parseVerbositySteer } from "./steer.js";
import { scrubSeverity } from "./scrub.js";
import { nextUpdate, type ProgressState } from "./progress.js";
import { gistOf, renderStatus, toolDetail } from "./status.js";
import type { RoomLineInput } from "./ui.js";
import { WithheldBuffer, withheldSummary } from "./withheld.js";
import { summarizeTurn, type TaskNote } from "./journal.js";
import { collectSessionMeta } from "./presence.js";
import { FreeqConnection, type BotFactory, type InboundAsk } from "./connection.js";
import { ConnectionLock } from "./lock.js";
import {
  HandoffStore,
  OfferQueue,
  WorkWatchdog,
  describeHandoff,
  type HandoffRecord,
} from "./handoff.js";
import { type KeyFetcher } from "./verify.js";
import {
  TurnRecorder,
  buildProvenance,
  PROVENANCE_EVENT,
  type ProvenanceTier,
} from "./provenance.js";
import { decideInbound, frameInbound, reachesModel, type InboundEvent } from "./inbound.js";
import type { Harness, InboundCard, NoticeLevel } from "./harness.js";

/** Root of freeq state on this machine — bot-kit's `~/.freeq`. */
export const FREEQ_ROOT = joinPath(homedir(), ".freeq");
/** Where bot-kit keeps per-identity state; one directory per minted identity. */
export const BOTS_ROOT = joinPath(FREEQ_ROOT, "bots");

/**
 * The owner's creator key, if an older `/freeq authorize` made one. When
 * present, bot-kit signs the installation's delegation certificate with it
 * and the server can verify that signature against a key the owner
 * registered. Absent, the cert ships unsigned and the server proves it from
 * the owner's agent record naming this installation (Settings → Agents in
 * the web app, or `freeq-bot-id register`).
 */
async function existingCreatorKey(cfg: { ownerDid?: string }): Promise<string | undefined> {
  if (!cfg.ownerDid) return undefined;
  const path = creatorKeyPath(FREEQ_ROOT, cfg.ownerDid);
  try {
    await fsAccess(path);
    return path;
  } catch {
    return undefined;
  }
}

/**
 * The HTTP origin that serves the key store, derived from the IRC websocket
 * URL (`wss://host/irc` → `https://host`).
 */
export function httpOriginFor(wsUrl: string): string {
  try {
    const u = new URL(wsUrl);
    u.protocol = u.protocol === "ws:" ? "http:" : "https:";
    u.pathname = "";
    u.search = "";
    return u.origin;
  } catch {
    return "https://irc.freeq.at";
  }
}

/**
 * Temporary seams for the parts of the session still driven by the harness
 * adapter (handoff events, resume, the maintenance loop). They move into the
 * runtime next and these go away.
 */
export interface RuntimeHooks {
  onActEvent?(ev: ActEventPayload): void;
  onOnline?(): void;
  afterConnect?(cfg: FreeqConfig): void;
  beforeStop?(): Promise<void> | void;
}

export interface RuntimeOptions {
  hooks?: RuntimeHooks;
  /** How the bot is built. Tests inject a fake; production omits it. */
  botFactory?: BotFactory;
}

/**
 * Things this session owes a reply to, in arrival order: peer asks, and
 * channel messages that addressed us.
 *
 * `seq` is the turn counter when the message arrived. A reply is only
 * flushed by a turn that STARTED after that — the text of a turn already in
 * flight was written before the model saw the message, and is not its
 * answer.
 */
type PendingReply =
  | { kind: "ask"; ask: InboundAsk; seq: number }
  | { kind: "channel"; channel: string; from: string; seq: number };

/** Provenance tier ordering. */
function tierAtLeastProv(a: ProvenanceTier, b: ProvenanceTier): boolean {
  const rank = { silent: 0, decisions: 1, evidence: 2, firehose: 3 } as const;
  return rank[a] >= rank[b];
}

export class AgentRuntime {
  config: FreeqConfig | undefined;
  sources: string[] = [];
  conn: FreeqConnection | undefined;
  agentDir: string;
  /**
   * Only one session per project talks to freeq. Identity is per project, so
   * without this every window in it connects as the same DID and nick:
   * presence becomes last-writer-wins and a single mention gets answered by
   * every window at once.
   */
  lock: ConnectionLock | undefined;
  passive = false;
  /** Keeps the lock file alive if something deletes it under us. */
  #lockTimer: NodeJS.Timeout | undefined;

  readonly #pendingReplies: PendingReply[] = [];
  /** Monotonic across runs; incremented at every turn start. */
  #turnSeq = 0;
  /** Text of the most recent assistant turn, used to form replies. */
  #lastAssistantText = "";

  // ── live work status ────────────────────────────────────────────────────
  //
  // A watching human should be able to tell, from a freeq client, whether
  // this agent is idle, thinking, or grinding on a specific task. Without
  // this the member list says "available" while the console is clearly busy.

  /**
   * What we're doing, for presence: a human phrase, the current tool, and
   * elapsed time — what a watcher needs to tell "thinking" from "stuck".
   * Set by beginStep (typed prompts, freeq triggers, handoffs, the model's
   * own `status` action), cleared when the run settles.
   */
  step: { phrase: string; since: number; tool?: string } | undefined;
  /** Keeps the elapsed part of the label honest during long, quiet steps. */
  #stepTimer: NodeJS.Timeout | undefined;
  /** Task id we're working, if this turn came from a handoff. */
  workTask: string | undefined;
  /**
   * The channel that asked for what we are doing now, if a room asked at all.
   *
   * A turn started by someone typing in the terminal has no such channel and
   * must stay silent: nobody in a room asked, so nobody in a room is owed a
   * progress report.
   */
  #askingChannel: string | undefined;
  /** Timer and memory for the live progress line. See progress.ts. */
  #updateTimer: NodeJS.Timeout | undefined;
  #updateState: ProgressState = {};
  /** Coalesce rapid tool-call updates — presence is not a debug log. */
  #lastStatusPush = 0;

  /** Accumulates this turn's consequences for the provenance log. */
  readonly turn = new TurnRecorder();

  // Messages addressed to us that the tier gate refused. Held so the agent
  // can say who is waiting instead of being indistinguishable from ignoring
  // them. See withheld.ts for why this exists.
  readonly withheld = new WithheldBuffer();
  currentProject: string | undefined;
  /**
   * True when we deliberately did not connect because this project has no
   * freeq identity yet. Cleared by the first thing that needs the wire.
   */
  dormant = false;

  /** Durable view of handoffs. Loaded once per session. */
  handoffs: HandoffStore | undefined;
  /** Resolves the exact key a signature names, from the server's key store. */
  keyFetcher: KeyFetcher | undefined;
  /** The connected server's own DID, read once; a move only the server may
   *  make counts only under this name. */
  serverDid: string | undefined;
  /** Briefs we authored, kept locally so we can show what we sent. */
  readonly localBriefs = new Map<string, string>();
  /** Offers waiting for this session to be free. Survives a restart. */
  offers: OfferQueue | undefined;
  /** Clocks on work we accepted. */
  watchdog: WorkWatchdog | undefined;
  /** Tasks this session has already re-entered — resume must be idempotent. */
  readonly resumed = new Set<string>();

  #lastModel: string | undefined;
  #lastFirehoseAt = 0;

  readonly hooks: RuntimeHooks;
  readonly #botFactory: BotFactory | undefined;

  constructor(
    readonly harness: Harness,
    options: RuntimeOptions = {},
  ) {
    this.agentDir = harness.agentDir;
    this.hooks = options.hooks ?? {};
    this.#botFactory = options.botFactory;
  }

  // ── presence ────────────────────────────────────────────────────────────

  /**
   * Post a progress line into the room that asked, if there is one and if
   * there is anything new to say. Silence is the default; `nextUpdate` owns
   * the rules.
   */
  #tickUpdate(cfg: FreeqConfig): void {
    const conn = this.conn;
    if (!this.#askingChannel || !conn || conn.state !== "online") return;
    if (cfg.muted || !cfg.enabled) return;
    const intervalMs = (cfg.updateIntervalSecs ?? 0) * 1000;
    if (intervalMs <= 0) return;
    const out = nextUpdate(this.#updateState, this.step, Date.now(), { intervalMs });
    if (!out) return;
    this.#updateState = out.state;
    try {
      conn.send(this.#askingChannel, out.text);
    } catch {
      /* a progress line is a courtesy; never let it disturb the turn */
    }
  }

  #startUpdates(cfg: FreeqConfig, channel: string): void {
    this.#askingChannel = channel;
    this.#updateState = {};
    const intervalMs = (cfg.updateIntervalSecs ?? 0) * 1000;
    if (this.#updateTimer || intervalMs <= 0) return;
    this.#updateTimer = setInterval(() => this.#tickUpdate(cfg), intervalMs);
    this.#updateTimer.unref?.();
  }

  #stopUpdates(): void {
    this.#askingChannel = undefined;
    this.#updateState = {};
    if (!this.#updateTimer) return;
    clearInterval(this.#updateTimer);
    this.#updateTimer = undefined;
  }

  /** The label a watcher sees right now, or undefined when idle. */
  currentLabel(): string | undefined {
    return this.step ? renderStatus(this.step, Date.now()) : undefined;
  }

  /**
   * Begin a named step. The phrase is the watcher-facing truth of the
   * moment, so it is force-pushed immediately (bypassing the coalescing
   * throttle) and then kept fresh on a slow timer for the elapsed counter.
   */
  beginStep(phrase: string): void {
    // The phrase is advertised to the whole room in presence: run it
    // through the same scrubber that keeps paths and secrets out of chat.
    const clean = this.conn ? this.conn.scrubForWire(phrase, "presence") : phrase;
    this.step = { phrase: clean, since: Date.now() };
    this.pushStatus("executing", this.currentLabel(), this.workTask, true);
    if (!this.#stepTimer) {
      this.#stepTimer = setInterval(() => {
        if (this.step) this.pushStatus("executing", this.currentLabel(), this.workTask);
      }, 45_000);
      this.#stepTimer.unref?.();
    }
    this.harness.stepBegan?.(phrase);
  }

  endStep(): void {
    this.step = undefined;
    if (this.#stepTimer) {
      clearInterval(this.#stepTimer);
      this.#stepTimer = undefined;
    }
  }

  pushStatus(state: string, label?: string, task?: string, force = false): void {
    const conn = this.conn;
    if (!conn || conn.state !== "online") return;
    const now = Date.now();
    if (!force && now - this.#lastStatusPush < 2500) return;
    this.#lastStatusPush = now;
    this.stateChanged();
    // The label is derived from prompts and message text, so it goes through
    // the same secret redaction as everything else on the wire.
    conn.setWorkState(state, label ? conn.scrubForWire(label, "presence") : label, task);
  }

  /** Ask the harness to repaint whatever it shows of this session. */
  stateChanged(): void {
    try {
      this.harness.stateChanged?.();
    } catch {
      /* presentation is best-effort */
    }
  }

  // ── stores ──────────────────────────────────────────────────────────────

  async ensureHandoffs(): Promise<HandoffStore> {
    if (this.handoffs) return this.handoffs;
    const store = new HandoffStore(HandoffStore.pathFor(this.agentDir));
    await store.load();
    this.handoffs = store;
    return store;
  }

  async ensureOffers(): Promise<OfferQueue> {
    if (this.offers) return this.offers;
    const q = new OfferQueue(OfferQueue.pathFor(this.agentDir));
    await q.load();
    this.offers = q;
    return q;
  }

  ensureWatchdog(cfg: FreeqConfig): WorkWatchdog {
    this.watchdog ??= new WorkWatchdog({
      progressIntervalSecs: cfg.progressIntervalSecs,
      stallSecs: cfg.stallSecs,
    });
    return this.watchdog;
  }

  // ── the person ──────────────────────────────────────────────────────────

  notify(text: string, level: NoticeLevel): void {
    try {
      this.harness.notify(text, level);
    } catch {
      /* best-effort */
    }
  }

  /** Something we posted to freeq, shown as a receipt. */
  #receipt(channel: string, text: string): void {
    try {
      this.harness.roomLine?.({
        direction: "out",
        channel,
        from: this.conn?.nick ?? "me",
        text,
      });
    } catch {
      /* best-effort */
    }
  }

  /** Room traffic shown but not delivered. */
  #surface(input: RoomLineInput): void {
    try {
      this.harness.roomLine?.(input);
    } catch {
      /* best-effort */
    }
  }

  async ensureConfig(): Promise<FreeqConfig> {
    if (this.config) return this.config;
    this.agentDir = this.harness.agentDir;
    const loaded = await loadConfig({
      agentDir: this.agentDir,
      cwd: this.harness.cwd(),
      configDirName: this.harness.configDirName,
      projectTrusted: this.harness.projectTrusted(),
    });
    this.config = loaded.config;
    this.sources = loaded.sources;
    if (!this.config.install) this.config.install = deriveInstallSlug();
    return this.config;
  }

  /**
   * Has this installation used freeq in this project before?
   *
   * Three signals, any of which means yes: the project has its own channel
   * list, a bot-kit state directory already exists for it (so a keypair was
   * minted at some point), or this is a git repository rather than a scratch
   * directory.
   */
  async #projectIsKnown(cfg: FreeqConfig): Promise<boolean> {
    const meta = await collectSessionMeta({ cwd: this.harness.cwd(), model: this.harness.modelId() });
    this.currentProject = meta.project;
    if (meta.project && cfg.projects?.[meta.project]) return true;
    const slug = cfg.install ?? deriveInstallSlug();
    const name = resolveBotName(slug, meta.project, (n: string) => existsSync(joinPath(BOTS_ROOT, n)));
    if (existsSync(joinPath(BOTS_ROOT, name))) return true;
    // A git checkout is somewhere someone means to keep working; a bare
    // directory is usually somewhere they are trying something out.
    return !!meta.repo || !!meta.branch;
  }

  // ── the ONE path from the network into the model ────────────────────────

  /**
   * Act on a decided inbound event. This is the only function in the package
   * that may put remote input in front of the model, and it refuses to do so
   * unless `decideInbound` said so.
   */
  deliver(ev: InboundEvent, opts?: { ask?: InboundAsk; replyToChannel?: boolean }): void {
    const ask = opts?.ask;
    const conn = this.conn;
    const decision = decideInbound(ev);

    if (!reachesModel(decision.action)) {
      if (decision.action === "surface") {
        this.#surface({
          direction: "in",
          channel: ev.channel,
          from: ev.from,
          did: ev.did ?? undefined,
          text: ev.text,
          // Someone waiting on an answer gets a marker; ordinary room
          // chatter does not need a justification attached to every line.
          note:
            ev.addressed || ev.kind === "ask"
              ? `withheld · tier ${ev.tier}`
              : undefined,
        });
        // Only messages meant for us. Room chatter we are merely not injecting
        // is not a message anyone is waiting on an answer to.
        if (ev.addressed || ev.kind === "ask") {
          this.withheld.add({
            did: ev.did ?? undefined,
            from: ev.from,
            channel: ev.channel,
            text: ev.text,
            reason: decision.reason,
            at: Date.now(),
          });
          const line = withheldSummary(this.withheld.senders());
          if (line) this.notify(`freeq: ${line}`, "warning");
          this.stateChanged();
        }
      }
      // An unanswerable ask still gets a reply — silence is indistinguishable
      // from a broken agent on the far side.
      if (ask && conn) {
        conn.replyToAsk(ask, undefined, `declined: ${decision.reason}`);
      }
      return;
    }

    const expectsReply = !!ask || !!opts?.replyToChannel;
    if (ask) {
      this.#pendingReplies.push({ kind: "ask", ask, seq: this.#turnSeq });
    } else if (opts?.replyToChannel) {
      this.#pendingReplies.push({ kind: "channel", channel: ev.channel, from: ev.from, seq: this.#turnSeq });
    }

    // Attribute the coming turn to whoever caused it, so a watcher sees
    // "answering chad in #freeq-dev" rather than an unexplained busy agent.
    // The phrase names who and where, never the message text: presence is
    // visible to every room we share, and one room's words are another's
    // metadata leak.
    if (expectsReply) {
      const venue = ev.channel.startsWith("#") ? ` in ${ev.channel}` : "";
      this.beginStep(`answering ${ev.from}${venue}`);
      // Somebody in a room is now waiting. The terminal narrates every step
      // of this; without this the room gets one line, whenever the turn
      // happens to end. A DM answers to the sender, a channel to the channel.
      // If we somehow got here before config loaded there is no interval to
      // honour, so stay quiet rather than crash the host.
      if (this.config) this.#startUpdates(this.config, ev.channel);
    }
    const framed = frameInbound(ev, { expectsReply });

    // Only addressed input from `request` tier and up interrupts a run.
    // Lower-tier chat waits; it should not interrupt work.
    const interrupts = ev.addressed && tierAtLeast(ev.tier, "request");
    try {
      this.harness.deliver({
        content: framed,
        interrupt: interrupts,
        card: {
          kind: ev.kind,
          channel: ev.channel,
          from: ev.from,
          did: ev.did,
          tier: ev.tier,
          text: ev.text,
          reason: decision.reason,
          expectsReply,
        } satisfies InboundCard,
      });
    } catch (err) {
      if (ask && conn) conn.replyToAsk(ask, undefined, `local delivery failed`);
      this.notify(`freeq: could not deliver message: ${(err as Error).message}`, "error");
    }
  }

  /**
   * Connect if we are dormant, minting this project's identity on the way.
   *
   * Called by everything that needs the wire. The first /freeq command in a
   * new project is the "reason" lazy minting waits for - deliberate use, as
   * against the harness merely having been started in a directory.
   */
  async wake(): Promise<void> {
    if (!this.dormant) return;
    this.dormant = false;
    const cfg = await this.ensureConfig();
    if (!cfg.enabled || !isDid(cfg.ownerDid)) return;
    this.notify("freeq: first use in this project — minting its identity", "info");
    const msg = await this.connect();
    if (this.conn?.state !== "online") this.notify(msg, "warning");
    this.stateChanged();
  }

  async connect(): Promise<string> {
    const cfg = await this.ensureConfig();
    if (!cfg.enabled) return "freeq is disabled (`/freeq on` to enable)";
    if (!isDid(cfg.ownerDid)) return "freeq: not logged in — run `/freeq login <did:plc:…>`";
    if (this.conn && this.conn.state !== "offline") return `freeq: already ${this.conn.state}`;
    // An existing-but-offline connection still owns a bot and possibly a
    // socket the transport is retrying. Replacing it without stopping it
    // leaks a session, which is how one process ended up holding three
    // connections and answering every mention three times.
    if (this.conn) {
      await this.conn.stop("replaced");
      this.conn = undefined;
    }

    // Claim this PROJECT's connection slot. The meta is collected first so the
    // lock, the identity and the nick all key off the same project name.
    const cwd = this.harness.cwd();
    const meta = await collectSessionMeta({ cwd, model: this.harness.modelId() });
    this.currentProject = meta.project;
    this.lock ??= new ConnectionLock(ConnectionLock.pathFor(this.agentDir, meta.project));
    const claim = await this.lock.acquire(cwd);
    if (!claim.held) {
      this.passive = true;
      return (
        `freeq: another pi session in this project holds the connection` +
        (claim.holder?.label ? ` (${claim.holder.label})` : "") +
        `. This window stays passive — one agent identity, one presence. ` +
        `Close that session, or run /freeq takeover here.`
      );
    }
    this.passive = false;

    // Re-assert the lock periodically: if the file vanishes the slot would
    // silently free up and the next window would connect alongside us.
    if (!this.#lockTimer) {
      this.#lockTimer = setInterval(() => {
        void (async () => {
          const stillOurs = await this.lock?.refresh(cwd);
          if (stillOurs === false && this.conn) {
            // Somebody took over deliberately. Stand down rather than fight.
            this.passive = true;
            await this.conn.stop("another session took over");
            this.conn = undefined;
            this.notify("freeq: another pi session took over the connection", "warning");
          }
        })();
      }, 60_000);
      this.#lockTimer.unref?.();
    }

    const conn = new FreeqConnection({
      ownerDid: cfg.ownerDid,
      server: cfg.server,
      slug: cfg.install ?? deriveInstallSlug(),
      root: BOTS_ROOT,
      nick: cfg.nick,
      creatorKeyPath: await existingCreatorKey(cfg),
      // Per-project: a music repo and a work repo are different agents and
      // belong in different rooms. Falls back to the global list.
      channels: channelsForProject(cfg, meta.project),
      meta,
      botFactory: this.#botFactory,
      onNotice: (text, level) => this.notify(text, level),

      onUnexpectedChannel: (channel) => {
        this.notify(
          `freeq: left ${channel} — the server had rejoined us there, but this project's channels are ${this.config ? channelsForProject(this.config, this.currentProject).join(", ") || "(none)" : "(none)"}`,
          "info",
        );
        this.stateChanged();
      },
      onJoinRefused: (channel, reason) => {
        // Loud, with the remedy, because the alternative is a channel that
        // looks joined and is not.
        this.notify(
          reason === "policy"
            ? `freeq: ${channel} refused the join — it requires policy acceptance. Run /freeq policy ${channel} accept`
            : `freeq: could not join ${channel} — ${reason}`,
          "warning",
        );
        this.stateChanged();
      },
      onScrub: (hits, target) => {
        // Not every redaction is news. Rewriting the home directory to `~`
        // loses nothing and used to fire a warning on every message, which is
        // how a notice stops being read before the one that matters arrives.
        const level = scrubSeverity(hits);
        if (level === "silent") return;
        const kinds = hits.filter((h) => h !== "home-path").join(", ") || hits.join(", ");
        this.notify(
          level === "warning"
            ? `freeq: redacted ${kinds} from a message to ${target} — check what you were about to send`
            : `freeq: shortened an absolute path in a message to ${target}`,
          level,
        );
      },

      onMessage: (channel, msg) => {
        void (async () => {
          const did = await this.conn!.resolveSenderDid(msg);
          const isChannel = channel.startsWith("#");
          // bot-kit's mention check also enforces a per-channel cooldown,
          // which is what stops two agents that mention each other from
          // ping-ponging forever.
          const mention = isChannel
            ? this.conn!.checkMention(channel, msg.text)
            : { addressed: true, stripped: msg.text, cooling: false };

          if (mention.cooling) {
            this.#surface({
              direction: "in",
              channel,
              from: msg.from,
              text: msg.text,
              note: "rate-limited · not answered",
            });
            return;
          }

          // Steering from the room, owner only. "be more verbose" typed into
          // freeq should do the same thing as /freeq verbosity in the
          // terminal - the person following along is the one who knows
          // whether it is too much or too little. Gated on the OWNER's DID
          // (server-resolved), never on the nick: anyone can call themselves
          // chad, and a config knob is exactly what an impostor would reach for.
          if (mention.addressed && did && did === cfg.ownerDid) {
            const steer = parseVerbositySteer(mention.stripped);
            if (steer) {
              cfg.provenance = steer;
              await saveConfig(this.agentDir, cfg);
              const words: Record<ProvenanceTier, string> = {
                silent: "I'll stop mirroring my work here entirely.",
                decisions: "I'll keep it quiet - only decisions, and only as tags.",
                evidence: "I'll post one line per turn here as I work.",
                firehose: "I'll narrate every consequential tool call as it happens.",
              };
              this.conn!.send(channel, `${msg.from}: ${words[steer]} (verbosity → ${steer})`);
              this.notify(`freeq: verbosity → ${steer} (set by ${msg.from} in ${channel})`, "info");
              return;
            }
          }

          this.deliver(
            {
              kind: "chat",
              channel,
              from: msg.from,
              did,
              text: mention.addressed ? mention.stripped : msg.text,
              addressed: mention.addressed,
              mode: modeFor(cfg, channel),
              tier: tierFor(cfg, did),
            },
            // Someone addressed us in a room: answer in the room.
            { replyToChannel: mention.addressed },
          );
        })();
      },

      onActEvent: (ev) => this.hooks.onActEvent?.(ev),

      // Every connect, including a reconnect after a dropped socket — the gap
      // is exactly when accepted work goes quiet without anybody deciding it
      // should.
      onOnline: () => {
        try {
          this.harness.connected?.();
        } catch {
          /* presentation is best-effort */
        }
        this.hooks.onOnline?.();
      },

      onAsk: (ask) => {
        this.deliver(
          {
            kind: "ask",
            channel: ask.channel,
            from: ask.from,
            did: ask.did,
            text: ask.question,
            addressed: true, // an ask is addressed by construction
            // An ask is a direct request, not room chatter: it is governed by
            // the tier gate, not by the venue's presentation mode. Mute still
            // wins, since mute means "say nothing anywhere".
            mode: cfg.muted ? "silent" : "addressed",
            tier: tierFor(cfg, ask.did),
          },
          { ask },
        );
      },
    });
    this.conn = conn;

    await conn.start();
    this.hooks.afterConnect?.(cfg);
    return `freeq: ${conn.describe()}`;
  }

  // ── lifecycle ───────────────────────────────────────────────────────────

  /** The session started: load config and connect if this project is known. */
  async start(): Promise<void> {
    const cfg = await this.ensureConfig();
    if (!cfg.enabled || !isDid(cfg.ownerDid)) return; // silent when not set up

    // Mint lazily. An identity is a keypair and a nick registered on a public
    // server, and connecting on sight meant every directory the harness was
    // ever started in acquired one — three throwaway test directories
    // produced three permanent agents, indistinguishable from real projects
    // to anyone reading the roster.
    //
    // A project this installation already knows still connects on sight, so
    // nothing about working in a real project changes. An unknown one waits
    // for a reason: any /freeq command connects, and so does anything else
    // that needs the wire. Trying freeq out should not cost you an identity.
    if (!(await this.#projectIsKnown(cfg))) {
      this.dormant = true;
      this.stateChanged();
      return;
    }
    const msg = await this.connect();
    if (this.conn?.state !== "online") this.notify(msg, "warning");

    // Surface work that arrived while this installation was offline. The
    // server replays channel history on join, so offers made overnight land
    // as replayed act events; anything still open is reported once here.
    const store = await this.ensureHandoffs();
    await this.ensureOffers();
    setTimeout(() => {
      const me = this.conn?.did;
      const waiting = store.inboxFor(me);
      if (waiting.length) {
        this.notify(
          `freeq: ${waiting.length} handoff(s) waiting for you:\n` +
            waiting.map((r: HandoffRecord) => `  ${describeHandoff(r, me)}`).join("\n") +
            `\n/freeq tasks to review, /freeq accept <id> to take one.`,
          "warning",
        );
      }
    }, 12_000).unref?.();
  }

  /** The session is ending. */
  async stop(reason = "pi session ended"): Promise<void> {
    await this.hooks.beforeStop?.();
    // Say why the work stopped rather than letting it simply go quiet. NOT a
    // failure: a restart may pick it straight back up (see resume), and a
    // false failure in a signed, permanent log is worse than a gap.
    for (const action of this.watchdog?.shutdown() ?? []) {
      if (action.kind !== "progress") continue;
      await this.conn?.sendAct(action.task.channel, "progress", action.task.taskId, {
        note: action.note,
      });
    }
    await this.offers?.save();
    await this.handoffs?.save();
    await this.conn?.stop(reason);
    this.conn = undefined;
    if (this.#lockTimer) {
      clearInterval(this.#lockTimer);
      this.#lockTimer = undefined;
    }
    // Hand the slot to the next window rather than making it wait for a
    // liveness check to notice we're gone.
    await this.lock?.release();
  }

  /** A run began. A run also counts as life, which is what the stall timeout measures. */
  onRunStart(): void {
    this.watchdog?.touch();
    this.pushStatus("executing", this.currentLabel() ?? "working", this.workTask, true);
  }

  /** A turn began. */
  onTurnStart(): void {
    this.#turnSeq++;
    // Presence liveness: tool calls already push state, but a long thinking
    // stretch makes none. A turn boundary is the other heartbeat — throttled
    // inside pushStatus, so this costs at most one presence line per 2.5s.
    this.pushStatus("executing", this.currentLabel() ?? "working", this.workTask);
  }

  /**
   * The person typed a prompt. It becomes the step phrase — this is where
   * "bash" turns into "looking at why reconnect drops channels". Framed freeq
   * input (anything starting `[freeq —`) is skipped: deliver already named
   * that step.
   */
  onUserPrompt(text: string): void {
    if (!text.trim() || text.startsWith("[freeq —")) return;
    // The first prompt of a run names the step. A steer mid-run must not
    // reset the phrase (and its elapsed clock) that the watcher follows —
    // and a handoff brief must not overwrite the task title as the phrase.
    if (!this.step) this.beginStep(gistOf(text));
  }

  /**
   * The model called a tool. Name it so a watcher sees movement, not just a
   * spinner, and note anything that counts as a consequence for the log.
   */
  onToolCall(toolName: string | undefined, input: Record<string, unknown> | undefined): void {
    // A tool call is the model doing something, which is exactly what the
    // stall timer needs to hear about — otherwise long, quiet work looks
    // stalled and gets failed out from under itself.
    this.watchdog?.touch();
    if (!toolName) return;
    // The tool is a suffix on the current phrase, never the headline —
    // "bash" alone is exactly the contentless status this replaces.
    if (this.step) this.step.tool = toolDetail(toolName, input);
    this.pushStatus("executing", this.currentLabel() ?? toolName, this.workTask);
    const config = this.config;
    if (config?.provenance) {
      this.turn.record({ name: toolName, input }, config.provenance);
      if (config.provenance === "firehose") {
        const i = input ?? {};
        const what =
          typeof i.command === "string" ? `bash: ${String(i.command).split("\n")[0].slice(0, 80)}` :
          typeof i.path === "string" ? `${toolName}: ${String(i.path).split(/[\\/]/).pop()}` :
          toolName;
        this.#firehose(config, what);
      }
    }
  }

  /**
   * A turn ended with this text; `hadToolCalls` when it also called tools.
   * Captures the text so an inbound ask can be answered with it.
   */
  onTurnEnd(text: string, hadToolCalls: boolean): void {
    if (text) this.#lastAssistantText = text;
    // A turn that made tool calls is narration ("fetching the forecast…"),
    // not the answer — the answer comes after the tools return. Flushing the
    // reply queue on it delivers the narration to the asker and the actual
    // answer to nobody (this exact misfire shipped a "Fetching a real
    // forecast" line to #chad-compute while the forecast stayed local).
    //
    // A turn taken while carrying a task is a step on that task. Journal the
    // gist so a restart resumes from here rather than from the title.
    if (text && this.workTask) this.journal("turn", this.workTask, summarizeTurn(text));
    // Answer NOW, not when the run ends. A steered message reaches the model
    // mid-task; the model answers it in its next text and carries on. If that
    // answer waited for the run to settle it would (a) arrive after the task
    // and (b) be overwritten by the task's wrap-up text. So the first turn
    // that produces text after a message arrived is the reply to it.
    if (text && !hadToolCalls && this.#pendingReplies.length) {
      this.#flushReplies(text, false, this.#turnSeq);
    }
  }

  /**
   * Send `text` to everyone waiting on this run. Called when a turn ends (the
   * live path) and when the run settles (the sweep for anything left,
   * including the "no answer produced" case that must never leave an asker
   * hanging).
   */
  #flushReplies(text: string, settled: boolean, beforeSeq?: number): void {
    const channelReplies = new Map<string, string>(); // channel -> last asker
    // Take only what this text can legitimately answer; leave the rest queued.
    const pending = this.#pendingReplies;
    const due = beforeSeq === undefined ? pending.splice(0) : [];
    if (beforeSeq !== undefined) {
      for (let i = pending.length - 1; i >= 0; i--) {
        if (pending[i]!.seq < beforeSeq) due.unshift(pending.splice(i, 1)[0]!);
      }
    }
    for (const item of due) {
      const conn = this.conn;
      if (!conn) continue;

      if (item.kind === "ask") {
        if (text) {
          conn.replyToAsk(item.ask, text);
          // A receipt in the transcript: what actually went back, and to whom.
          this.#receipt(item.ask.from, text);
        } else {
          // An empty answer is a real state — report it, never leave the
          // asker hanging until timeout.
          conn.replyToAsk(item.ask, undefined, "no answer produced");
          if (settled) this.notify(`freeq: no answer produced for ${item.ask.from}`, "warning");
        }
        continue;
      }

      // Channel replies are collected and sent once per channel below. A
      // turn produces ONE answer; if four messages queued while we worked,
      // that answer used to go out four times, once per queued item.
      if (!text) continue;
      channelReplies.set(item.channel, item.from);
    }
    // Sent whole: the SDK splits long text into a draft/multiline BATCH, so a
    // cap here only ever threw away the end of an answer - the part that
    // usually held the conclusion, after paying the tokens to produce it.
    for (const [channel, from] of channelReplies) {
      const conn = this.conn;
      if (!conn) break;
      // Membership first: a PRIVMSG to a channel we are not in is dropped
      // server-side and the sender never finds out — the receipt below would
      // be a lie. JOIN is ordered before the PRIVMSG on the same socket and
      // is a no-op when already a member — and membership can be lost
      // without the client knowing (nick churn from sibling sessions), so
      // join unconditionally. Channels only: a DM target is a nick, and
      // JOIN <nick> is nonsense.
      if (channel.startsWith("#")) conn.join(channel);
      conn.send(channel, `${from}: ${text}`);
      // A receipt in the transcript: what we handed the server, addressed so.
      this.#receipt(channel, `${from}: ${text}`);
    }
  }

  /** The run settled: the model is idle again. */
  async onSettled(): Promise<void> {
    // Pay back whatever this run was triggered by and hasn't been answered
    // yet — normally nothing, since onTurnEnd answers live. What is left here
    // is a run that ended without ever producing text.
    this.#flushReplies(this.#lastAssistantText, true);
    this.#lastAssistantText = "";

    // Mirror what this turn actually changed. Before the offline early-return
    // below, so the recorder is always drained — otherwise a turn taken while
    // disconnected would leak into the next one's summary.
    await this.#mirrorTurn(this.config ?? (await this.ensureConfig()));

    const conn = this.conn;
    if (!conn || conn.state !== "online") return;

    // Back to available. Clearing the step matters: a stale "working on X"
    // is worse than no status at all.
    this.endStep();
    this.#stopUpdates();
    this.workTask = undefined;
    this.pushStatus("active", undefined, undefined, true);

    const model = this.harness.modelId();
    if (model === this.#lastModel) return;
    this.#lastModel = model;
    conn.updateMeta({ ...conn.meta, model });
  }

  /**
   * Leave a breadcrumb in the journal for the task in flight.
   *
   * The server remembers WHAT is assigned; this remembers HOW far it got.
   */
  journal(kind: TaskNote["kind"], taskId: string, text: string): void {
    if (!text.trim()) return;
    const note: TaskNote = { taskId, at: Date.now(), kind, text };
    this.harness.journal.append(note);
  }

  /**
   * Publish this turn's consequences as a signed coordination event.
   *
   * Deliberately one line per turn. The point is a log a person will still
   * read in six months, which rules out a running commentary of every tool
   * call — that is what the `firehose` tier is for, and why it is not the
   * default.
   */
  async #mirrorTurn(cfg: FreeqConfig): Promise<void> {
    const tier = cfg.provenance ?? "decisions";
    const conn = this.conn;
    if (tier === "silent" || cfg.muted || !conn || conn.state !== "online") {
      this.turn.reset();
      return;
    }
    const summary = this.turn.summary();
    const files = this.turn.files;
    this.turn.reset();
    if (!summary) return; // a turn that changed nothing says nothing

    const channel = cfg.provenanceChannel ?? cfg.channels[0];
    if (!channel) return;

    const payload = buildProvenance({
      v: 1,
      kind: "turn",
      text: summary,
      files: files.length ? files : undefined,
    });
    try {
      conn.sendTags(channel, {
        "+freeq.at/event": PROVENANCE_EVENT,
        "+freeq.at/payload": encodeURIComponent(JSON.stringify(payload)),
      });
      // At `evidence` and above the room also gets it as readable text, not
      // only as a tag most clients do not render.
      if (tierAtLeastProv(tier, "evidence")) {
        conn.send(channel, `⚙ ${summary}${files.length ? `  [${files.join(", ")}]` : ""}`);
      }
    } catch {
      // The log is a side effect; never let it disturb the session.
    }
  }

  /**
   * Live per-tool lines, `firehose` only. One line as each consequential tool
   * call starts, so a watcher sees the agent move rather than a summary after
   * the fact. Rate-limited: a burst of reads is one line, not forty.
   */
  #firehose(cfg: FreeqConfig, line: string): void {
    if ((cfg.provenance ?? "evidence") !== "firehose" || cfg.muted) return;
    const conn = this.conn;
    if (!conn || conn.state !== "online") return;
    const channel = cfg.provenanceChannel ?? cfg.channels[0];
    if (!channel) return;
    const now = Date.now();
    if (now - this.#lastFirehoseAt < 1500) return;
    this.#lastFirehoseAt = now;
    try {
      conn.send(channel, `⚙ ${line}`);
    } catch {
      /* side effect */
    }
  }
}
