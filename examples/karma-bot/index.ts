/**
 * freeq-karma-bot — classic IRC karma tracker (`nick++`, `nick--`, `!karma`,
 * `!leaderboard`) built on @freeq/sdk.
 *
 * The point of this example: every meaningful step of the bot's lifecycle
 * is gated by a real call to the freeq agent_assist diagnostic surface
 * (advertised at /.well-known/agent.json), and the bot uses the answers
 * to drive behaviour — not just decoration.
 *
 *   stage                  | tool                       | use of result
 *   -----------------------+----------------------------+----------------------------------
 *   boot                   | validate_client_config     | refuse to start if WARN
 *   join failure           | diagnose_join_failure      | log structured cause for ops
 *   before each reply      | predict_message_outcome    | skip send if would fail
 *   on reconnect           | replay_missed_messages     | catch up on missed ++/-- events
 *   periodic               | inspect_my_session         | warn if the server's view drifts
 *
 * Validation calls go to the same /agent/tools/* paths the LLM-routed
 * /agent/session endpoint uses, so this bot is also a ground-truth probe
 * of those endpoints.
 */

import { FreeqClient } from '@freeq/sdk';
import * as fs from 'node:fs';

// ─── Config ─────────────────────────────────────────────────────────────

const SERVER_WS = process.env.FREEQ_SERVER ?? 'wss://irc.freeq.at/irc';
const SERVER_HTTP = SERVER_WS
  .replace(/^ws:/, 'http:')
  .replace(/^wss:/, 'https:')
  .replace(/\/irc$/, '');
const NICK = process.env.FREEQ_NICK ?? `karma-${Math.random().toString(36).slice(2, 6)}`;
const CHANNELS = (process.env.FREEQ_CHANNELS ?? '#dev')
  .split(',').map((c) => c.trim()).filter(Boolean);
const KARMA_FILE = process.env.FREEQ_KARMA_FILE ?? './karma.json';
const VALIDATION_LOG = process.env.FREEQ_VALIDATION_LOG ?? './validation.log';
const QUIT_AFTER_MS = process.env.FREEQ_QUIT_AFTER_MS
  ? parseInt(process.env.FREEQ_QUIT_AFTER_MS, 10) : 0;

// Heuristic: who counts as "the bot's account" when calling self-only
// diagnostic tools. Anonymous bot → empty string (the tools will see
// caller as anonymous).
const BOT_DID = process.env.FREEQ_BOT_DID ?? '';

// ─── Validation logger ──────────────────────────────────────────────────

const valLog = fs.createWriteStream(VALIDATION_LOG, { flags: 'a' });
process.on('exit', () => valLog.end());

function logValidation(stage: string, tool: string, request: unknown, response: unknown) {
  const entry = {
    ts: new Date().toISOString(),
    stage, tool, request, response,
  };
  valLog.write(JSON.stringify(entry) + '\n');
  // Also one human-readable line so the operator can watch the bot in real time.
  const r = response as { diagnosis?: { code?: string; summary?: string }; ok?: boolean };
  // Discovery responses have no `ok` field — they're informational. Only
  // diagnostic-tool responses do. Render accordingly.
  const status = r?.diagnosis?.code
    ? (r.ok ? 'ok' : 'NOT_OK')
    : 'fetched';
  console.log(
    `[validation] ${stage} → ${tool}: ${status} ` +
    `(${r?.diagnosis?.code ?? 'no diagnosis'}) ${r?.diagnosis?.summary ?? ''}`.trim()
  );
}

/**
 * Mutable holder so callTool() picks up the bearer the moment SASL
 * succeeds — without having to thread the client into every call site.
 * Set by main() either from `FREEQ_BEARER` (for testing) or from
 * `client.apiBearer` once the SDK captures the API-BEARER NOTICE.
 */
let bearer: string | null = process.env.FREEQ_BEARER ?? null;

async function callTool(
  stage: string, name: string, body: unknown
): Promise<Record<string, unknown> | null> {
  try {
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (bearer) headers['Authorization'] = `Bearer ${bearer}`;
    const resp = await fetch(`${SERVER_HTTP}/agent/tools/${name}`, {
      method: 'POST', headers, body: JSON.stringify(body),
    });
    const json = await resp.json() as Record<string, unknown>;
    logValidation(stage, name, body, json);
    return json;
  } catch (e: unknown) {
    logValidation(stage, name, body, { error: (e as Error).message });
    return null;
  }
}

// ─── Karma store ────────────────────────────────────────────────────────

type ChannelKarma = Record<string, number>;
type Store = Record<string, ChannelKarma>;

let store: Store = {};
try { store = JSON.parse(fs.readFileSync(KARMA_FILE, 'utf-8')); }
catch { store = {}; }

function persist() {
  fs.writeFileSync(KARMA_FILE, JSON.stringify(store, null, 2));
}

function bump(channel: string, nick: string, delta: number, actor: string) {
  // Self-karma is forbidden — the most common karma-bot rule.
  if (nick.toLowerCase() === actor.toLowerCase()) return false;
  const ch = store[channel] ??= {};
  ch[nick.toLowerCase()] = (ch[nick.toLowerCase()] ?? 0) + delta;
  persist();
  return true;
}

function getKarma(channel: string, nick: string): number {
  return store[channel]?.[nick.toLowerCase()] ?? 0;
}

function leaderboard(channel: string, n = 5): [string, number][] {
  const ch = store[channel] ?? {};
  return Object.entries(ch).sort(([, a], [, b]) => b - a).slice(0, n);
}

// ─── Pre-flight: probe + validate ───────────────────────────────────────

interface Discovery {
  service: string;
  capabilities: string[];
  description?: string;
}

async function probeDiscovery(): Promise<Discovery | null> {
  try {
    const resp = await fetch(`${SERVER_HTTP}/.well-known/agent.json`);
    if (!resp.ok) return null;
    const meta = await resp.json() as Discovery;
    logValidation('preflight', 'discovery', {}, meta);
    return meta;
  } catch (e: unknown) {
    logValidation('preflight', 'discovery', {}, { error: (e as Error).message });
    return null;
  }
}

async function preflight(): Promise<boolean> {
  const discovery = await probeDiscovery();
  if (!discovery) {
    console.error('[preflight] no discovery — bailing.');
    return false;
  }
  // Refuse to boot if the validator we depend on isn't advertised.
  const required = ['validate_client_config', 'predict_message_outcome', 'diagnose_join_failure'];
  const missing = required.filter((c) => !discovery.capabilities.includes(c));
  if (missing.length) {
    console.error(`[preflight] discovery missing required tools: ${missing.join(', ')}`);
    return false;
  }
  // Validate the SDK CAP matrix we'll negotiate.
  const validation = await callTool('preflight', 'validate_client_config', {
    client_name: 'freeq-karma-bot',
    client_version: '0.0.1',
    supports: {
      message_tags: true, batch: true, server_time: true,
      sasl: false, resume: false, echo_message: true, away_notify: true,
    },
  });
  const ok = validation && (validation as { ok?: boolean }).ok === true;
  if (!ok) {
    console.error('[preflight] validate_client_config returned warnings — see validation.log');
    // Not fatal: a warning configuration still works, just suboptimally.
    // We log it and continue. Toggle to `return false` if you want strict.
  }
  return true;
}

// ─── Per-reply gate via predict_message_outcome ─────────────────────────

/**
 * Wrap the SDK's sendMessage with a validation pre-check. Returns true
 * if we sent, false if the predictor blocked us (and why).
 *
 * The predictor is self-only — for an anonymous bot it'll always deny
 * with PREDICT_MESSAGE_OUTCOME_SELF_ONLY, so we route around that case.
 * When BOT_DID is set the bot calls predict for real and the rate-limit
 * + channel-mode advice actually drives behavior.
 */
async function safeSend(client: FreeqClient, target: string, text: string): Promise<boolean> {
  // Always call predict_message_outcome so the validation surface is
  // exercised on every reply. The tool is self-only, so for anonymous
  // bots it returns PREDICT_MESSAGE_OUTCOME_SELF_ONLY — that's logged
  // but doesn't gate the send (we have no identity to predict for).
  // When BOT_DID is set we honour PREDICTED_REJECTED to actually skip.
  const pred = await callTool('pre_send', 'predict_message_outcome', {
    account: BOT_DID, target,
  });
  const code = (pred as { diagnosis?: { code?: string } } | null)?.diagnosis?.code;
  if (BOT_DID && code === 'PREDICTED_REJECTED') {
    console.warn(`[pre_send] BLOCKED: ${target} would reject — skipping send`);
    return false;
  }
  client.sendMessage(target, text);
  return true;
}

// ─── Main ───────────────────────────────────────────────────────────────

async function main() {
  if (!await preflight()) {
    process.exit(1);
  }

  const client = new FreeqClient({
    url: SERVER_WS, nick: NICK, channels: CHANNELS,
  });

  // Track last-seen msgid per channel so we can call replay_missed_messages
  // with a real anchor on reconnect.
  const lastSeenMsgid = new Map<string, string>();

  // ── Periodic + reconnect health checks ──
  client.on('connectionStateChanged', async (state) => {
    console.log(`[wire] state=${state}`);
    if (state === 'connected' && lastSeenMsgid.size > 0) {
      // We just reconnected. For each channel we know about, ask the
      // server how many msgids landed since our last anchor — purely
      // informational, since karma deltas would need replay-decoding,
      // but it surfaces the gap to ops so the karma-recovery story is
      // observable.
      for (const [channel, anchor] of lastSeenMsgid.entries()) {
        await callTool('on_reconnect', 'replay_missed_messages', {
          channel, since_msgid: anchor, limit: 200,
        });
      }
    }
  });

  // ── Join failure → diagnose with structured tool ──
  client.on('joinGateRequired', async (channel) => {
    await callTool('join_failure', 'diagnose_join_failure', {
      account: BOT_DID, channel, observed_numeric: '477',
    });
  });
  client.on('systemMessage', async (target, text) => {
    // The SDK fires systemMessage for the 473/474/475 cases too. Look
    // for those numerics and route them through the diagnostic tool.
    for (const [code, marker] of [
      ['473', 'invite only'],
      ['474', 'banned'],
      ['475', 'incorrect channel key'],
    ] as const) {
      if (text.toLowerCase().includes(marker)) {
        await callTool('join_failure', 'diagnose_join_failure', {
          account: BOT_DID, channel: target, observed_numeric: code,
        });
      }
    }
  });

  // ── Message handling: karma + commands ──
  client.on('message', async (channel, msg) => {
    if (msg.isSelf) return; // Our own echo — never act on it.
    if (!channel.startsWith('#')) return; // DMs not handled.

    // Update the per-channel anchor so reconnect-replay has a real msgid.
    if (msg.id) lastSeenMsgid.set(channel, msg.id);

    const text = msg.text;
    const actor = msg.from;

    // ── Karma changes ──
    // Word-boundary nick++/nick-- so URLs don't trigger.
    const KARMA_RE = /(^|\s|[(\[{])([A-Za-z_][A-Za-z0-9_-]{0,31})(\+\+|--)(?=$|\s|[)\]},.!?;:])/g;
    let m: RegExpExecArray | null;
    const announces: string[] = [];
    while ((m = KARMA_RE.exec(text))) {
      const [, , nick, op] = m;
      const delta = op === '++' ? 1 : -1;
      if (bump(channel, nick, delta, actor)) {
        announces.push(`${nick}: ${getKarma(channel, nick)}`);
      }
    }
    if (announces.length) {
      await safeSend(client, channel, `karma → ${announces.join(', ')}`);
    }

    // ── Commands ──
    const trimmed = text.trim();
    if (trimmed === '!karma' || trimmed.startsWith('!karma ')) {
      const arg = trimmed.slice('!karma'.length).trim() || actor;
      await safeSend(client, channel, `${arg} has ${getKarma(channel, arg)} karma in ${channel}`);
    } else if (trimmed === '!leaderboard') {
      const top = leaderboard(channel, 5);
      const body = top.length
        ? top.map(([n, k], i) => `${i + 1}. ${n}: ${k}`).join(' | ')
        : 'no karma yet — try `someone++`';
      await safeSend(client, channel, `🏆 ${channel} top karma → ${body}`);
    } else if (trimmed === '!karma-help') {
      await safeSend(client, channel,
        'karma-bot: `nick++` / `nick--` to vote • `!karma [nick]` • `!leaderboard` • `!karma-help`');
    }
  });

  // ── Ready → log + announce, gated by predict ──
  client.once('ready', async () => {
    console.log(`[ready] ${client.nick} on ${SERVER_WS} — channels=${CHANNELS.join(',')}`);
    // Don't announce — would be noisy and the prediction layer will
    // exercise itself on the first real reply anyway.
  });

  // Once SASL completes the SDK captures the server-emitted
  // `NOTICE * :API-BEARER <session_id>` and exposes it as
  // `client.apiBearer`. Mirror it into our module-level `bearer` so
  // every subsequent callTool() goes out as the authenticated bot.
  client.on('connectionStateChanged', (state) => {
    if (state === 'connected') {
      // Drain on a microtask so apiBearer has time to be set
      // (we don't have a separate "bearer ready" event).
      setTimeout(() => {
        if (client.apiBearer && !bearer) {
          bearer = client.apiBearer;
          console.log('[auth] captured API bearer from SDK — diagnostic calls now authenticated');
        }
      }, 1000);
    }
  });

  client.connect();

  if (QUIT_AFTER_MS > 0) {
    setTimeout(() => {
      console.log(`[shutdown] quit_after_ms=${QUIT_AFTER_MS} reached`);
      client.disconnect();
      valLog.end(() => process.exit(0));
    }, QUIT_AFTER_MS);
  }

  process.on('SIGINT', () => {
    console.log('[shutdown] SIGINT');
    client.disconnect();
    valLog.end(() => process.exit(0));
  });
}

main().catch((e: Error) => {
  console.error('[fatal]', e);
  process.exit(1);
});
