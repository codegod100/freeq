/**
 * full-validation-bot — flagship demo of the freeq agent assistance
 * surface used at full power.
 *
 * The bot:
 *   1. Generates a fresh did:key (or imports a saved one from ./seed.bin).
 *   2. Connects via SASL ATPROTO-CHALLENGE using the new crypto / did:key
 *      flow in @freeq/sdk — no PDS, no OAuth, no broker.
 *   3. Captures the API-BEARER NOTICE → uses it as `Authorization:
 *      Bearer …` on every /agent/tools/* call.
 *   4. Exercises every advertised diagnostic tool and acts on the
 *      structured answers:
 *
 *        validate_client_config       — gate boot
 *        inspect_my_session           — confirm the server's view
 *        diagnose_join_failure        — explain why a JOIN fails
 *        predict_message_outcome      — gate every reply
 *        replay_missed_messages       — gap report on reconnect
 *        explain_message_routing      — interpret incoming wire lines
 *
 *   5. Logs every request/response to ./validation.log as JSONL.
 *
 * Run:
 *   npm install && npm start
 *
 * It connects to wss://irc.freeq.at/irc as a fresh anonymous-but-
 * cryptographically-identified bot. The DID it shows you is owned
 * solely by the keypair on disk in ./seed.bin — keep it safe to keep
 * the same identity between runs, delete it to rotate.
 */

import { FreeqClient, generateDidKey, importDidKey, type DidKey } from '@freeq/sdk';
import * as fs from 'node:fs';

// ─── Config ─────────────────────────────────────────────────────────────

const SERVER_WS = process.env.FREEQ_SERVER ?? 'wss://irc.freeq.at/irc';
const SERVER_HTTP = SERVER_WS
  .replace(/^ws:/, 'http:')
  .replace(/^wss:/, 'https:')
  .replace(/\/irc$/, '');
const NICK = process.env.FREEQ_NICK ?? `valbot-${Math.random().toString(36).slice(2, 6)}`;
const CHANNELS = (process.env.FREEQ_CHANNELS ?? '#dev')
  .split(',').map((c) => c.trim()).filter(Boolean);
const SEED_FILE = process.env.FREEQ_SEED_FILE ?? './seed.bin';
const VALIDATION_LOG = process.env.FREEQ_VALIDATION_LOG ?? './validation.log';
const QUIT_AFTER_MS = process.env.FREEQ_QUIT_AFTER_MS
  ? parseInt(process.env.FREEQ_QUIT_AFTER_MS, 10) : 0;

// ─── Validation logger ──────────────────────────────────────────────────

const valLog = fs.createWriteStream(VALIDATION_LOG, { flags: 'a' });
process.on('exit', () => valLog.end());

let bearer: string | null = process.env.FREEQ_BEARER ?? null;

function log(stage: string, tool: string, request: unknown, response: unknown) {
  const entry = { ts: new Date().toISOString(), stage, tool, request, response };
  valLog.write(JSON.stringify(entry) + '\n');
  const r = response as { ok?: boolean; diagnosis?: { code?: string; summary?: string } };
  const status = r?.diagnosis?.code ? (r.ok ? '✓' : '✗') : '·';
  console.log(`[${stage}] ${tool} ${status} ${r?.diagnosis?.code ?? ''} ${r?.diagnosis?.summary ?? ''}`.trimEnd());
}

async function callTool(stage: string, name: string, body: unknown): Promise<Record<string, unknown> | null> {
  try {
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (bearer) headers['Authorization'] = `Bearer ${bearer}`;
    const resp = await fetch(`${SERVER_HTTP}/agent/tools/${name}`, {
      method: 'POST', headers, body: JSON.stringify(body),
    });
    const json = await resp.json() as Record<string, unknown>;
    log(stage, name, body, json);
    return json;
  } catch (e: unknown) {
    log(stage, name, body, { error: (e as Error).message });
    return null;
  }
}

async function probeDiscovery() {
  try {
    const resp = await fetch(`${SERVER_HTTP}/.well-known/agent.json`);
    const meta = await resp.json();
    log('preflight', 'discovery', {}, meta);
    return meta as { capabilities: string[] };
  } catch {
    return null;
  }
}

// ─── Identity: load or generate a did:key ───────────────────────────────

async function loadOrGenerate(): Promise<DidKey> {
  if (fs.existsSync(SEED_FILE)) {
    const seed = new Uint8Array(fs.readFileSync(SEED_FILE));
    const key = await importDidKey(seed);
    console.log(`[identity] loaded existing did:key from ${SEED_FILE}`);
    console.log(`[identity] DID: ${key.did}`);
    return key;
  }
  const key = await generateDidKey();
  const seed = await key.exportSeed();
  fs.writeFileSync(SEED_FILE, seed, { mode: 0o600 });
  console.log(`[identity] generated fresh did:key and saved seed to ${SEED_FILE}`);
  console.log(`[identity] DID: ${key.did}`);
  return key;
}

// ─── Pre-send gate via predict_message_outcome ──────────────────────────

async function safeSend(client: FreeqClient, did: string, target: string, text: string): Promise<boolean> {
  const pred = await callTool('pre_send', 'predict_message_outcome', {
    account: did, target,
  });
  const code = (pred as { ok?: boolean; diagnosis?: { code?: string } } | null)?.diagnosis?.code;
  // PREDICTED_REJECTED is the predictor saying "this would fail at the
  // server" — rate-limited, +m, not in channel, etc. Skip the send.
  if (code === 'PREDICTED_REJECTED') {
    console.warn(`[pre_send] BLOCKED: send to ${target} rejected — skipping`);
    return false;
  }
  client.sendMessage(target, text);
  return true;
}

// ─── Main ───────────────────────────────────────────────────────────────

async function main() {
  const discovery = await probeDiscovery();
  if (!discovery?.capabilities?.length) {
    console.error('[boot] no discovery — server unreachable or wrong URL?');
    process.exit(1);
  }

  const id = await loadOrGenerate();

  // Pre-flight validation — refuse to boot if our config has warnings.
  // The validator is public (no auth) so this works even before SASL.
  const cfg = await callTool('preflight', 'validate_client_config', {
    client_name: 'freeq-full-validation-bot',
    client_version: '0.0.1',
    supports: {
      message_tags: true, batch: true, server_time: true,
      sasl: true, resume: false, echo_message: true, away_notify: true,
    },
  });
  if (!(cfg as { ok?: boolean })?.ok) {
    console.warn('[boot] validate_client_config returned warnings — see validation.log');
  }

  const client = new FreeqClient({
    url: SERVER_WS,
    nick: NICK,
    channels: CHANNELS,
    sasl: {
      did: id.did,
      method: 'crypto',
      signer: id.signer,
      // Token + pdsUrl unused for crypto method, but the type requires them.
      token: '',
      pdsUrl: '',
    },
  });

  // Track per-channel last-seen msgid for replay_missed_messages on reconnect.
  const lastSeenMsgid = new Map<string, string>();

  // Pick up the API-BEARER as soon as SASL completes.
  client.on('connectionStateChanged', async (state) => {
    if (state === 'connected') {
      // Wait briefly for the post-SASL NOTICE to land + be parsed.
      await new Promise((r) => setTimeout(r, 1500));
      if (client.apiBearer) {
        bearer = client.apiBearer;
        console.log(`[auth] captured API bearer — diagnostic surface now authenticated as ${id.did}`);

        // First call we make as the authenticated bot: inspect_my_session.
        // The result confirms the server's view matches ours; if drift,
        // log it.
        await callTool('post_auth', 'inspect_my_session', { account: id.did });

        // If we'd remembered an anchor msgid, replay any missed.
        for (const [channel, anchor] of lastSeenMsgid.entries()) {
          await callTool('on_reconnect', 'replay_missed_messages', {
            channel, since_msgid: anchor, limit: 200,
          });
        }
      } else {
        console.warn('[auth] expected an API bearer but client.apiBearer is null — running anonymous');
      }
    }
  });

  // Real diagnostic on any join failure.
  client.on('joinGateRequired', async (channel) => {
    await callTool('join_failure', 'diagnose_join_failure', {
      account: id.did, channel, observed_numeric: '477',
    });
  });
  client.on('systemMessage', async (target, text) => {
    for (const [code, marker] of [
      ['473', 'invite only'],
      ['474', 'banned'],
      ['475', 'incorrect channel key'],
    ] as const) {
      if (text.toLowerCase().includes(marker)) {
        await callTool('join_failure', 'diagnose_join_failure', {
          account: id.did, channel: target, observed_numeric: code,
        });
      }
    }
  });

  // Demonstrate explain_message_routing on a real captured line every
  // time we receive a message that matches our nick — useful when
  // building mention-detection logic and unsure if the SDK saw it as
  // a mention (false-positive guard).
  client.on('raw', async (line, _parsed) => {
    // Only invoke on PRIVMSG that mentions us (cheap heuristic).
    if (!line.includes('PRIVMSG') || !line.toLowerCase().includes(client.nick.toLowerCase())) return;
    await callTool('explain', 'explain_message_routing', {
      wire_line: line, my_nick: client.nick,
    });
  });

  // Track msgids for replay_missed_messages on the next reconnect.
  client.on('message', (channel, msg) => {
    if (msg.id) lastSeenMsgid.set(channel, msg.id);
  });

  // Commands the bot responds to — every reply pre-checked via predict.
  client.on('message', async (channel, msg) => {
    if (msg.isSelf) return;
    if (!channel.startsWith('#')) return;
    const text = msg.text.trim();
    if (text === '!ping') {
      await safeSend(client, id.did, channel, 'pong');
    } else if (text === '!whoami') {
      await safeSend(client, id.did, channel, `I am ${id.did} (nick=${client.nick})`);
    } else if (text === '!validate-help') {
      await safeSend(client, id.did, channel,
        'commands: !ping • !whoami • !validate-help • !inspect (DM only)');
    } else if (text === '!inspect' && !channel.startsWith('#')) {
      // DM-only debug command: ask the server what it sees about us
      // and reply with a summary.
      const r = await callTool('on_demand', 'inspect_my_session', { account: id.did });
      const facts = (r as { safe_facts?: string[] } | null)?.safe_facts ?? [];
      await safeSend(client, id.did, channel, facts.slice(0, 3).join(' | '));
    }
  });

  client.once('ready', () => {
    console.log(`[ready] ${client.nick} on ${SERVER_WS} channels=${CHANNELS.join(',')}`);
  });

  client.connect();

  if (QUIT_AFTER_MS > 0) {
    setTimeout(() => {
      console.log('[shutdown] timeout');
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
