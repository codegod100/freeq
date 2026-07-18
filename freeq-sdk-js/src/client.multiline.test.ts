/**
 * Unit tests for the JS SDK's `draft/multiline` wire support — both
 * outbound chunking (sendMessage / sendMultiline routing to a BATCH
 * when the cap is acked) and inbound assembly (BATCH chunks reassemble
 * into a single `message` event with the assembled body).
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import type { FreeqClient } from './client.js';
import type { Message } from './types.js';

// ── WebSocket mock (mirrors client.test.ts so multiline tests are self-contained) ──

type ReadyState = 0 | 1 | 2 | 3;

class MockWebSocket {
  static CONNECTING: ReadyState = 0;
  static OPEN: ReadyState = 1;
  static CLOSING: ReadyState = 2;
  static CLOSED: ReadyState = 3;
  static instances: MockWebSocket[] = [];

  CONNECTING: ReadyState = 0;
  OPEN: ReadyState = 1;
  CLOSING: ReadyState = 2;
  CLOSED: ReadyState = 3;

  url: string;
  readyState: ReadyState = 0;
  bufferedAmount = 0;
  sent: string[] = [];

  onopen: ((ev: unknown) => void) | null = null;
  onmessage: ((ev: { data: string }) => void) | null = null;
  onclose: ((ev: unknown) => void) | null = null;
  onerror: ((ev: unknown) => void) | null = null;

  constructor(url: string) {
    this.url = url;
    MockWebSocket.instances.push(this);
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.({});
    });
  }

  send(data: string): void {
    if (this.readyState !== 1) return;
    this.sent.push(data);
  }

  close(): void {
    this.readyState = 3;
    this.onclose?.({});
  }

  recv(line: string): void {
    this.onmessage?.({ data: line + '\r\n' });
  }
}

beforeEach(() => {
  MockWebSocket.instances = [];
  // @ts-expect-error mock global
  globalThis.WebSocket = MockWebSocket;
  if (!globalThis.crypto || !(globalThis.crypto as { randomUUID?: () => string }).randomUUID) {
    Object.defineProperty(globalThis, 'crypto', {
      value: {
        randomUUID: () => 'uuid-' + Math.random().toString(36).slice(2),
        subtle: {
          generateKey: () => Promise.reject(new Error('Ed25519 unavailable in test env')),
        },
      },
      configurable: true,
      writable: true,
    });
  }
});

afterEach(() => {
  vi.restoreAllMocks();
});

async function flushAsync(): Promise<void> {
  // Each ws.recv() chains another handleLine onto a serialized queue
  // (`lineQueue`), so multiline tests with N chunks need N+ microtask
  // ticks to fully drain. Be generous here — the BATCH dispatch path
  // adds its own awaits on top.
  for (let i = 0; i < 32; i++) await Promise.resolve();
}

/**
 * Build a connected client that has negotiated `draft/multiline` +
 * `batch`. ACK is offered via the server CAP LS line so the SDK
 * actually requests + tracks them as acked.
 */
async function makeMultilineClient(nick = 'alice'): Promise<{
  client: FreeqClient;
  ws: MockWebSocket;
}> {
  const { FreeqClient } = await import('./client.js');
  const client = new FreeqClient({
    url: 'wss://test/irc',
    nick,
    skipInitialBrokerRefresh: true,
  });
  client.connect();
  await flushAsync();
  const ws = MockWebSocket.instances[MockWebSocket.instances.length - 1]!;
  ws.recv(
    ':srv CAP * LS :message-tags server-time batch echo-message ' +
      'draft/multiline=max-bytes=40000,max-lines=100',
  );
  await flushAsync();
  // Server ACKs the requested caps (the SDK CAP-REQ logic asks for these)
  ws.recv(':srv CAP * ACK :message-tags server-time batch draft/multiline');
  await flushAsync();
  ws.recv(`:srv 001 ${nick} :Welcome`);
  await flushAsync();
  ws.sent.length = 0;
  return { client, ws };
}

/**
 * Same builder but the server does NOT advertise `draft/multiline`.
 * Lets us test the legacy single-PRIVMSG fallback path.
 */
async function makeLegacyClient(nick = 'alice'): Promise<{
  client: FreeqClient;
  ws: MockWebSocket;
}> {
  const { FreeqClient } = await import('./client.js');
  const client = new FreeqClient({
    url: 'wss://test/irc',
    nick,
    skipInitialBrokerRefresh: true,
  });
  client.connect();
  await flushAsync();
  const ws = MockWebSocket.instances[MockWebSocket.instances.length - 1]!;
  ws.recv(':srv CAP * LS :message-tags server-time'); // no batch, no draft/multiline
  await flushAsync();
  ws.recv(':srv CAP * ACK :message-tags server-time');
  await flushAsync();
  ws.recv(`:srv 001 ${nick} :Welcome`);
  await flushAsync();
  ws.sent.length = 0;
  return { client, ws };
}

// ────────────────────────────────────────────────────────────────────
// CAP REQ negotiation
// ────────────────────────────────────────────────────────────────────

describe('draft/multiline CAP REQ', () => {
  it('requests draft/multiline when server advertises it with params', async () => {
    const { FreeqClient } = await import('./client.js');
    const client = new FreeqClient({
      url: 'wss://test/irc',
      nick: 'cap-tester',
      skipInitialBrokerRefresh: true,
    });
    client.connect();
    await flushAsync();
    const ws = MockWebSocket.instances[MockWebSocket.instances.length - 1]!;
    ws.recv(
      ':srv CAP * LS :batch draft/multiline=max-bytes=40000,max-lines=100',
    );
    await flushAsync();
    const capReq = ws.sent.find((l) => l.startsWith('CAP REQ'));
    expect(capReq).toBeDefined();
    expect(capReq!).toContain('draft/multiline');
    expect(capReq!).toContain('batch');
  });

  it('does NOT request draft/multiline when not advertised', async () => {
    const { FreeqClient } = await import('./client.js');
    const client = new FreeqClient({
      url: 'wss://test/irc',
      nick: 'cap-tester',
      skipInitialBrokerRefresh: true,
    });
    client.connect();
    await flushAsync();
    const ws = MockWebSocket.instances[MockWebSocket.instances.length - 1]!;
    ws.recv(':srv CAP * LS :batch message-tags');
    await flushAsync();
    const capReq = ws.sent.find((l) => l.startsWith('CAP REQ')) ?? '';
    expect(capReq).not.toContain('draft/multiline');
  });
});

// ────────────────────────────────────────────────────────────────────
// Outbound routing: sendMessage / sendMultiline
// ────────────────────────────────────────────────────────────────────

describe('outbound: sendMessage with multiline cap acked', () => {
  it('emits BATCH frames when text contains \\n', async () => {
    const { client, ws } = await makeMultilineClient();
    client.sendMessage('#room', 'line one\nline two\nline three');
    await flushAsync();
    const opener = ws.sent.find((l) => l.includes('BATCH +') && l.includes('draft/multiline'));
    const closer = ws.sent.find((l) => /BATCH -\S+/.test(l));
    const privmsgs = ws.sent.filter((l) => l.includes('PRIVMSG #room'));
    expect(opener).toBeDefined();
    expect(closer).toBeDefined();
    expect(privmsgs).toHaveLength(3);
    expect(privmsgs[0]).toContain('line one');
    expect(privmsgs[1]).toContain('line two');
    expect(privmsgs[2]).toContain('line three');
    // Each chunk carries batch=<id>
    const m = opener!.match(/BATCH \+(\S+)/);
    const batchId = m![1];
    for (const p of privmsgs) {
      expect(p).toContain(`batch=${batchId}`);
    }
  });

  it('length-splits a >6400B line with draft/multiline-concat (no + prefix — server/spec form)', async () => {
    const { client, ws } = await makeMultilineClient();
    // A single source line longer than the per-chunk budget must split into a
    // first (non-concat) chunk + concat continuation(s). The concat tag MUST be
    // `draft/multiline-concat` — no `+` client-tag prefix — or the server (and
    // peers) drop it and inject a raw \n at the split, corrupting the body.
    const longLine = 'word '.repeat(2000).trim(); // ~9999B single source line
    client.sendMessage('#room', `A\n${longLine}\nB`); // \n triggers multiline
    await flushAsync();
    const chunks = ws.sent.filter((l) => /\bPRIVMSG #room\b/.test(l));
    // A, the long line (split into >1), and B → more than 3 chunks.
    expect(chunks.length).toBeGreaterThan(3);
    // At least one concat continuation (the long line's length-split).
    const concatCount = chunks.filter((l) => l.includes('draft/multiline-concat')).length;
    expect(concatCount).toBeGreaterThanOrEqual(1);
    // And never the buggy `+`-prefixed form.
    expect(ws.sent.some((l) => l.includes('+draft/multiline-concat'))).toBe(false);
  });

  it('preserves blank lines (paragraph breaks) — emits an empty chunk, not dropped', async () => {
    const { client, ws } = await makeMultilineClient();
    // A blank line between paragraphs must survive byte-for-byte. Dropping
    // it breaks the multiline round-trip: rendering loses paragraph spacing,
    // and commit-reveal hashes over the original (blank lines intact) no
    // longer match the reassembled reveal body.
    client.sendMessage('#room', 'para one\n\npara two');
    await flushAsync();
    const privmsgs = ws.sent.filter((l) => l.includes('PRIVMSG #room'));
    expect(privmsgs).toHaveLength(3); // "para one", "" (blank), "para two"
    expect(privmsgs[0]).toContain('para one');
    expect(privmsgs[1]).not.toContain('para'); // the blank line, still emitted
    expect(privmsgs[2]).toContain('para two');
  });

  it('emitted batch reassembles byte-for-byte like the server (commit-reveal parity)', async () => {
    const { client, ws } = await makeMultilineClient();
    const answer =
      'First paragraph, reasonably long sentence to exercise things.\n\n' +
      'Second paragraph.\n- bullet one\n- bullet two\n\nClosing thought.';
    client.sendMessage('#room', answer);
    await flushAsync();
    const marker = 'PRIVMSG #room :';
    const chunks = ws.sent
      .filter((l) => l.includes(marker))
      .map((l) => ({
        concat: l.includes('draft/multiline-concat'),
        body: l.slice(l.indexOf(marker) + marker.length).replace(/\r?\n$/, ''),
      }));
    // Mirror server assemble_body: '\n' before each non-concat line except the first.
    let assembled = '';
    chunks.forEach((c, i) => {
      if (i > 0 && !c.concat) assembled += '\n';
      assembled += c.body;
    });
    expect(assembled).toBe(answer);
  });

  it('multilines a long single-line message (no \\n) instead of truncating', async () => {
    const { client, ws } = await makeMultilineClient();
    // No newlines, but bigger than one PRIVMSG. Must still BATCH (length-split
    // into concat chunks) rather than fall to the truncating legacy path.
    const bigNoNewlines = 'word '.repeat(2000).trim(); // ~9999B, zero '\n'
    client.sendMessage('#room', bigNoNewlines);
    await flushAsync();
    const opener = ws.sent.find((l) => l.includes('BATCH +') && l.includes('draft/multiline'));
    const chunks = ws.sent.filter((l) => /\bPRIVMSG #room\b/.test(l));
    expect(opener).toBeDefined(); // it batched despite no '\n'
    expect(chunks.length).toBeGreaterThan(1); // length-split
    expect(chunks.filter((l) => l.includes('draft/multiline-concat')).length).toBe(
      chunks.length - 1, // one non-concat opener chunk, rest concat
    );
  });

  it('falls through to single PRIVMSG when text has no \\n', async () => {
    const { client, ws } = await makeMultilineClient();
    client.sendMessage('#room', 'single line');
    await flushAsync();
    const opener = ws.sent.find((l) => l.includes('BATCH +'));
    const privmsg = ws.sent.find((l) => l.includes('PRIVMSG #room :single line'));
    expect(opener).toBeUndefined(); // no batch for single-line
    expect(privmsg).toBeDefined();
  });

  it('does NOT emit +freeq.at/multiline tag on BATCH path (real \\n carried via wire)', async () => {
    const { client, ws } = await makeMultilineClient();
    client.sendMessage('#room', 'a\nb');
    await flushAsync();
    expect(ws.sent.some((l) => l.includes('+freeq.at/multiline'))).toBe(false);
  });
});

describe('outbound: sendMessage without multiline cap (legacy)', () => {
  it('falls back to single PRIVMSG with escaped \\n and +freeq.at/multiline tag', async () => {
    const { client, ws } = await makeLegacyClient();
    client.sendMessage('#room', 'a\nb\nc');
    await flushAsync();
    const opener = ws.sent.find((l) => l.includes('BATCH +'));
    expect(opener).toBeUndefined();
    const privmsg = ws.sent.find((l) => l.includes('PRIVMSG #room'));
    expect(privmsg).toBeDefined();
    expect(privmsg!).toContain('+freeq.at/multiline');
    expect(privmsg!).toContain('a\\nb\\nc');
  });
});

describe('outbound: sendMultiline (explicit API)', () => {
  it('accepts a string body and emits BATCH', async () => {
    const { client, ws } = await makeMultilineClient();
    client.sendMultiline('#room', 'one\ntwo');
    await flushAsync();
    const opener = ws.sent.find((l) => l.includes('BATCH +') && l.includes('draft/multiline'));
    expect(opener).toBeDefined();
    // Batch id is async (await signing); not synchronously returned.
    const m = opener!.match(/BATCH \+(ml\w+)/);
    expect(m).not.toBeNull();
  });

  it('accepts an array body, joined with \\n', async () => {
    const { client, ws } = await makeMultilineClient();
    client.sendMultiline('#room', ['alpha', 'beta', 'gamma']);
    await flushAsync();
    const privmsgs = ws.sent.filter((l) => l.includes('PRIVMSG #room'));
    expect(privmsgs).toHaveLength(3);
    expect(privmsgs[0]).toContain('alpha');
    expect(privmsgs[1]).toContain('beta');
    expect(privmsgs[2]).toContain('gamma');
  });

  it('threads opener tags via options.tags onto the BATCH opener only', async () => {
    const { client, ws } = await makeMultilineClient();
    client.sendMultiline('#room', 'x\ny', { tags: { '+reply': 'msg-abc' } });
    await flushAsync();
    const opener = ws.sent.find((l) => l.includes('BATCH +'));
    const privmsgs = ws.sent.filter((l) => l.includes('PRIVMSG #room'));
    expect(opener!).toContain('+reply=msg-abc');
    for (const p of privmsgs) {
      expect(p).not.toContain('+reply=msg-abc');
    }
  });

  it('chunks DO NOT carry +freeq.at/sig — sigs ride on the opener', async () => {
    // We can't easily provision a signing key in the test env (Web
    // Crypto Ed25519 is platform-dependent), so we just verify the
    // CHUNK PRIVMSGs are clean. The opener-sig case is exercised in
    // the comprehensive test that runs under a real signing context.
    const { client, ws } = await makeMultilineClient();
    client.sendMultiline('#room', 'a\nb\nc');
    await flushAsync();
    const privmsgs = ws.sent.filter((l) => l.includes('PRIVMSG #room'));
    for (const p of privmsgs) {
      expect(p).not.toContain('+freeq.at/sig');
    }
  });
});

// ────────────────────────────────────────────────────────────────────
// Inbound: BATCH assembly
// ────────────────────────────────────────────────────────────────────

describe('inbound: draft/multiline assembly', () => {
  it('reassembles N PRIVMSG chunks into one `message` event with real \\n', async () => {
    const { client, ws } = await makeMultilineClient();
    const seen: Array<{ ch: string; msg: Message }> = [];
    client.on('message', (ch, msg) => seen.push({ ch, msg }));
    ws.recv(
      '@msgid=01XYZ;time=2026-05-29T17:00:00.000Z :bob!u@h BATCH +ab1 draft/multiline #room',
    );
    ws.recv('@batch=ab1 :bob!u@h PRIVMSG #room :hello');
    ws.recv('@batch=ab1 :bob!u@h PRIVMSG #room :world');
    ws.recv('@batch=ab1 :bob!u@h PRIVMSG #room :foo');
    ws.recv(':srv BATCH -ab1');
    await flushAsync();
    expect(seen).toHaveLength(1);
    expect(seen[0].ch).toBe('#room');
    expect(seen[0].msg.text).toBe('hello\nworld\nfoo');
    expect(seen[0].msg.id).toBe('01XYZ');
    expect(seen[0].msg.from).toBe('bob');
  });

  it('honors draft/multiline-concat (joins without separator)', async () => {
    const { client, ws } = await makeMultilineClient();
    const seen: Array<{ ch: string; msg: Message }> = [];
    client.on('message', (ch, msg) => seen.push({ ch, msg }));
    ws.recv('@msgid=01ABC :bob!u@h BATCH +ab2 draft/multiline #room');
    ws.recv('@batch=ab2 :bob!u@h PRIVMSG #room :alpha');
    ws.recv('@batch=ab2;draft/multiline-concat= :bob!u@h PRIVMSG #room :beta');
    ws.recv('@batch=ab2 :bob!u@h PRIVMSG #room :gamma');
    ws.recv(':srv BATCH -ab2');
    await flushAsync();
    expect(seen).toHaveLength(1);
    expect(seen[0].msg.text).toBe('alphabeta\ngamma');
  });

  it('does NOT emit per-chunk message events while batch is open', async () => {
    const { client, ws } = await makeMultilineClient();
    const seen: unknown[] = [];
    client.on('message', (ch, msg) => seen.push({ ch, msg }));
    ws.recv('@msgid=01X :bob!u@h BATCH +ab3 draft/multiline #room');
    ws.recv('@batch=ab3 :bob!u@h PRIVMSG #room :one');
    ws.recv('@batch=ab3 :bob!u@h PRIVMSG #room :two');
    await flushAsync();
    expect(seen).toHaveLength(0); // not until BATCH -<id>
    ws.recv(':srv BATCH -ab3');
    await flushAsync();
    expect(seen).toHaveLength(1);
  });

  it('routes an opener with +draft/edit through messageEdited (not message)', async () => {
    const { client, ws } = await makeMultilineClient();
    const messages: unknown[] = [];
    const edits: unknown[] = [];
    client.on('message', (...args) => messages.push(args));
    client.on('messageEdited', (...args) => edits.push(args));
    ws.recv(
      '@msgid=02ED;+draft/edit=01ORIG :bob!u@h BATCH +ed1 draft/multiline #room',
    );
    ws.recv('@batch=ed1 :bob!u@h PRIVMSG #room :corrected line 1');
    ws.recv('@batch=ed1 :bob!u@h PRIVMSG #room :corrected line 2');
    ws.recv(':srv BATCH -ed1');
    await flushAsync();
    expect(messages).toHaveLength(0);
    expect(edits).toHaveLength(1);
    // edits = [[bufName, editOf, newText, msgid, isStreaming]]
    expect((edits[0] as unknown[])[1]).toBe('01ORIG');
    expect((edits[0] as unknown[])[2]).toBe('corrected line 1\ncorrected line 2');
  });
});

// ────────────────────────────────────────────────────────────────────
// Inbound: legacy `+freeq.at/multiline` decode normalization
// ────────────────────────────────────────────────────────────────────

describe('inbound: legacy +freeq.at/multiline decode', () => {
  it('SDK decodes \\\\n → \\n so consumers see real line breaks', async () => {
    const { client, ws } = await makeMultilineClient();
    const seen: Array<Message> = [];
    client.on('message', (_ch, msg) => seen.push(msg));
    ws.recv(
      '@msgid=01LG;+freeq.at/multiline= :bob!u@h PRIVMSG #room :line a\\nline b\\nline c',
    );
    await flushAsync();
    expect(seen).toHaveLength(1);
    expect(seen[0].text).toBe('line a\nline b\nline c');
  });

  it('does NOT alter text on a regular PRIVMSG (no tag, no decode)', async () => {
    const { client, ws } = await makeMultilineClient();
    const seen: Array<Message> = [];
    client.on('message', (_ch, msg) => seen.push(msg));
    ws.recv(':bob!u@h PRIVMSG #room :literal \\n stays \\n literal');
    await flushAsync();
    expect(seen).toHaveLength(1);
    expect(seen[0].text).toBe('literal \\n stays \\n literal');
  });
});
