/**
 * Regression tests for the broader "client state survives wire-state regression"
 * bug class. The fixed-overnight-Guest bug was the auth instance; these are the
 * same shape applied to other cached state:
 *
 *   - channel encryption (+E / -E) vs the cached e2ee key
 *   - AWAY status vs an idle reconnect that resets it server-side
 *
 * Each test drives a real FreeqClient through a mock WebSocket and asserts
 * the SDK keeps its local cache in sync with the wire — or fails loudly.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as e2ee from './e2ee.js';

// ── WebSocket mock ────────────────────────────────────────────────

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

  onopen: ((ev: any) => void) | null = null;
  onmessage: ((ev: { data: string }) => void) | null = null;
  onclose: ((ev: any) => void) | null = null;
  onerror: ((ev: any) => void) | null = null;

  constructor(url: string) {
    this.url = url;
    MockWebSocket.instances.push(this);
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.({});
    });
  }

  send(data: string) {
    if (this.readyState !== 1) return;
    this.sent.push(data);
  }

  close() {
    this.readyState = 3;
    this.onclose?.({});
  }

  recv(line: string) {
    this.onmessage?.({ data: line + '\r\n' });
  }
}

beforeEach(() => {
  MockWebSocket.instances = [];
  // @ts-expect-error mock global
  globalThis.WebSocket = MockWebSocket;
  if (!globalThis.crypto || !(globalThis.crypto as any).randomUUID) {
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

async function flushAsync() {
  for (let i = 0; i < 5; i++) await Promise.resolve();
}

/** Drive registration to completion as a guest (no SASL). */
async function registerAsGuest(ws: MockWebSocket, nick: string) {
  await flushAsync();
  ws.recv(':srv CAP * LS :message-tags server-time batch echo-message account-notify extended-join away-notify');
  await flushAsync();
  // Client sends CAP REQ; ack it.
  ws.recv(`:srv CAP ${nick} ACK :message-tags server-time batch echo-message account-notify extended-join away-notify`);
  await flushAsync();
  ws.recv(`:srv 001 ${nick} :Welcome to freeq, ${nick} (guest)`);
  await flushAsync();
}

// ═══════════════════════════════════════════════════════════════════
// Channel encryption mode (+E / -E) vs cached e2ee key
// ═══════════════════════════════════════════════════════════════════

describe('channel encryption mode flip vs cached e2ee key', () => {
  it('MODE -E #ch must drop the e2ee channel key (current bug: key persists; sendMessage keeps encrypting)', async () => {
    const { FreeqClient } = await import('./client.js');
    const client = new FreeqClient({
      url: 'wss://test/irc',
      nick: 'me',
    });

    // Pretend we already have an e2ee key for #secret. We can't run the
    // real HKDF in this env, so spy on hasChannelKey/removeChannelKey
    // and assert the SDK calls remove on -E.
    const removeSpy = vi.spyOn(e2ee, 'removeChannelKey');

    client.connect();
    const ws = MockWebSocket.instances[0];
    await registerAsGuest(ws, 'me');

    // Server flips encryption off.
    ws.recv(':admin!u@h MODE #secret -E');
    await flushAsync();

    expect(
      removeSpy,
      'SDK must call e2ee.removeChannelKey when -E is received, otherwise sendMessage will keep encrypting with a key the channel no longer expects',
    ).toHaveBeenCalledWith('#secret');
  });

  it('MODE +E #ch + sendMessage with no key must NOT silently send plaintext into an encrypted channel', async () => {
    const { FreeqClient } = await import('./client.js');
    const client = new FreeqClient({
      url: 'wss://test/irc',
      nick: 'me',
    });

    client.connect();
    const ws = MockWebSocket.instances[0];
    await registerAsGuest(ws, 'me');

    // Server marks #secret encrypted. We have no passphrase set.
    ws.recv(':admin!u@h MODE #secret +E');
    await flushAsync();

    const before = ws.sent.length;
    client.sendMessage('#secret', 'plaintext leak');
    await flushAsync();
    const newLines = ws.sent.slice(before);
    const leakedPrivmsg = newLines.find(l => /^(@[^ ]* )?PRIVMSG #secret /i.test(l));

    expect(
      leakedPrivmsg,
      'sendMessage must not write a plaintext PRIVMSG into a +E channel when we have no key',
    ).toBeUndefined();
  });

  it('after MODE +E, re-receiving MODE -E must allow plaintext sends again', async () => {
    // Symmetric to the previous test: once the channel is no longer
    // encrypted, the SDK should allow normal sends again.
    const { FreeqClient } = await import('./client.js');
    const client = new FreeqClient({
      url: 'wss://test/irc',
      nick: 'me',
    });

    client.connect();
    const ws = MockWebSocket.instances[0];
    await registerAsGuest(ws, 'me');

    ws.recv(':admin!u@h MODE #room +E');
    await flushAsync();
    ws.recv(':admin!u@h MODE #room -E');
    await flushAsync();

    const before = ws.sent.length;
    client.sendMessage('#room', 'this is fine');
    await flushAsync();
    const newLines = ws.sent.slice(before);
    const sentPrivmsg = newLines.find(l => /^(@[^ ]* )?PRIVMSG #room /i.test(l));

    expect(sentPrivmsg, 'sendMessage must work normally after -E').toBeDefined();
  });
});

// ═══════════════════════════════════════════════════════════════════
// AWAY status vs reconnect
// ═══════════════════════════════════════════════════════════════════

describe('AWAY status vs reconnect', () => {
  it('after reconnect, the SDK must re-send AWAY so other clients still see us as away', async () => {
    // The user goes AFK. Server records us as away and broadcasts via
    // away-notify. WebSocket drops, transport reconnects; server forgot
    // we were away. The SDK must re-assert AWAY on registration so the
    // wire-state matches what the user (and store) believe.
    const { FreeqClient } = await import('./client.js');
    const client = new FreeqClient({
      url: 'wss://test/irc',
      nick: 'me',
    });

    client.connect();
    const ws1 = MockWebSocket.instances[0];
    await registerAsGuest(ws1, 'me');

    client.setAway('lunch');
    await flushAsync();
    ws1.recv(':srv 306 me :You have been marked as being away');
    await flushAsync();

    // Verify AWAY was actually sent (sanity).
    expect(ws1.sent.some(l => l.startsWith('AWAY '))).toBe(true);

    // Simulate a transport drop + auto-reconnect by tearing down the
    // first ws and forcing the SDK to reconnect.
    ws1.close();
    await flushAsync();
    client.reconnect();
    await flushAsync();
    const ws2 = MockWebSocket.instances[1];
    expect(ws2, 'expected a new WebSocket after reconnect').toBeDefined();
    await registerAsGuest(ws2, 'me');

    const reSentAway = ws2.sent.find(l => /^AWAY (:lunch|lunch)/.test(l));
    expect(
      reSentAway,
      'SDK must re-send AWAY on reconnect; otherwise the server thinks we are present and the wire/UI states diverge',
    ).toBeDefined();
  });

  it('clearing AWAY must not be re-sent on reconnect', async () => {
    // Inverse: if we are not away, reconnect should not spuriously
    // declare AWAY.
    const { FreeqClient } = await import('./client.js');
    const client = new FreeqClient({
      url: 'wss://test/irc',
      nick: 'me',
    });

    client.connect();
    const ws1 = MockWebSocket.instances[0];
    await registerAsGuest(ws1, 'me');

    client.setAway('back');
    ws1.recv(':srv 306 me :You have been marked as being away');
    client.setAway(undefined); // clear
    ws1.recv(':srv 305 me :You are no longer marked as being away');
    await flushAsync();

    ws1.close();
    await flushAsync();
    client.reconnect();
    await flushAsync();
    const ws2 = MockWebSocket.instances[1];
    await registerAsGuest(ws2, 'me');

    const sawAway = ws2.sent.find(l => /^AWAY /.test(l));
    expect(sawAway, 'no AWAY should be re-sent if we cleared it before reconnect').toBeUndefined();
  });
});
