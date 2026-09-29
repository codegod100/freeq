// @vitest-environment jsdom
/**
 * The Agents list on opening, through the real read: the stored rows show,
 * then the account's PDS is listed afresh and its rows replace them. With
 * the PDS unreachable the stored rows stay and nothing is reported. The
 * network is the SDK's stub repository and stub home server, so the records
 * are proven as they are in use.
 */
import 'fake-indexeddb/auto';
import { webcrypto } from 'node:crypto';
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render, cleanup, screen, waitFor } from '@testing-library/react';
import { stubHome, stubRepo, type StubHome, type StubRepo } from '../../../freeq-sdk-js/test/repo-proofs';

Object.defineProperty(globalThis, 'crypto', { value: webcrypto, writable: true, configurable: true });

const { buildAgentRecord, buildDeviceRecord, generateDidKey, recordKeyOf } = await import('@freeq/sdk');
const client = await import('../irc/client');
const { AgentsSection } = await import('./SettingsPanel');

const PDS = 'https://pds.agentsread.test';

let owner: string;
let repo: StubRepo;
let home: StubHome;
let key: Awaited<ReturnType<typeof recordKeyOf>>;
let pdsDown = false;

function serve(): void {
  vi.stubGlobal('fetch', async (input: string | URL | Request): Promise<Response> => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url);
    if (url.hostname === 'plc.directory') return Response.json(await repo.document(PDS));
    if (url.origin === PDS) {
      if (pdsDown) return new Response('unavailable', { status: 503 });
      return (await repo.respond(url)) ?? new Response('not found', { status: 404 });
    }
    if (url.origin === window.location.origin) {
      return (await home.respond(url)) ?? new Response('not found', { status: 404 });
    }
    return new Response('unexpected', { status: 500 });
  });
}

async function claim(label: string, hoursAgo: number): Promise<unknown> {
  const at = new Date(Date.now() - hoursAgo * 3600_000).toISOString();
  return buildAgentRecord(key, owner, (await generateDidKey()).did, at, label);
}

/** The names the list shows. */
const names = () => screen.queryAllByTestId('agent-name').map((e) => e.textContent);

beforeEach(async () => {
  // A new account each test: the client keeps one key lookup per account.
  owner = `did:plc:agentsread${Math.random().toString(36).slice(2, 10)}`;
  pdsDown = false;
  const pair = (await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify'])) as CryptoKeyPair;
  key = await recordKeyOf(pair);
  repo = await stubRepo(owner);
  await repo.add(
    'at.freeq.deviceKey',
    await buildDeviceRecord(key, owner, new Date(Date.now() - 48 * 3600_000).toISOString(), 'laptop'),
  );
  await repo.add('at.freeq.agentKey', await claim('helper', 24));
  home = stubHome([repo]);
  serve();
  client.setSaslCredentials('', owner, '', '');
  // The home server's copy is taken now, before anything else is written.
  home.frozen = true;
  await home.respond(new URL(`${window.location.origin}/api/v1/records/${owner}/at.freeq.agentKey`));
  await home.respond(new URL(`${window.location.origin}/api/v1/records/${owner}/at.freeq.deviceKey`));
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe('the Agents list on opening', () => {
  it('shows an agent added elsewhere once the fresh read returns', async () => {
    // Written by another device or by freeq-bot-id: only at the PDS.
    await repo.add('at.freeq.agentKey', await claim('added elsewhere', 1));
    render(<AgentsSection />);
    await waitFor(() => expect(names()).toEqual(['added elsewhere', 'helper']));
  });

  it('keeps the stored rows, and says nothing, when the PDS cannot be reached', async () => {
    pdsDown = true;
    render(<AgentsSection />);
    await waitFor(() => expect(names()).toEqual(['helper']));
    // Long enough for the fresh read to have failed.
    await new Promise((r) => setTimeout(r, 200));
    expect(names()).toEqual(['helper']);
    expect(screen.queryByText(/couldn't|try again|failed/i)).toBeNull();
  });
});
