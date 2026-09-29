// @vitest-environment jsdom
/**
 * `listAgentRows` reading the account through the connection's real key
 * lookup, as `listDeviceRows` does: the stored read takes the home server's
 * copy, and `refresh` lists the account's PDS afresh. The network is the
 * SDK's stub repository and stub home server, so the records are proven as
 * they are in use.
 */
import 'fake-indexeddb/auto';
import { webcrypto } from 'node:crypto';
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { stubHome, stubRepo, type StubHome, type StubRepo } from '../../../freeq-sdk-js/test/repo-proofs';

Object.defineProperty(globalThis, 'crypto', { value: webcrypto, writable: true, configurable: true });

const bridge = await import('./client');
const { buildAgentRecord, buildDeviceRecord, generateDidKey, recordKeyOf } = await import('@freeq/sdk');

const OWNER = 'did:plc:agentrowsowner';
const PDS = 'https://pds.agentrows.test';

let repo: StubRepo;
let home: StubHome;
let key: Awaited<ReturnType<typeof recordKeyOf>>;

/** The account's PDS, the PLC directory and this origin's home server. */
function serve(): void {
  vi.stubGlobal('fetch', async (input: string | URL | Request): Promise<Response> => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url);
    if (url.hostname === 'plc.directory') return Response.json(await repo.document(PDS));
    if (url.origin === PDS) return (await repo.respond(url)) ?? new Response('not found', { status: 404 });
    if (url.origin === window.location.origin) {
      return (await home.respond(url)) ?? new Response('not found', { status: 404 });
    }
    return new Response('unexpected', { status: 500 });
  });
}

async function claim(label: string, hoursAgo: number): Promise<unknown> {
  const at = new Date(Date.now() - hoursAgo * 3600_000).toISOString();
  return buildAgentRecord(key, OWNER, (await generateDidKey()).did, at, label);
}

beforeEach(async () => {
  const pair = (await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify'])) as CryptoKeyPair;
  key = await recordKeyOf(pair);
  repo = await stubRepo(OWNER);
  await repo.add('at.freeq.deviceKey', await buildDeviceRecord(key, OWNER, new Date(Date.now() - 48 * 3600_000).toISOString(), 'laptop'));
  await repo.add('at.freeq.agentKey', await claim('helper', 24));
  home = stubHome([repo]);
  serve();
  bridge.setSaslCredentials('', OWNER, '', '');
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('listAgentRows', () => {
  it('reads the stored copy, and lists the PDS afresh with refresh, as the device list does', async () => {
    home.frozen = true;
    expect((await bridge.listAgentRows()).map((r) => r.name)).toEqual(['helper']);

    await repo.add('at.freeq.agentKey', await claim('second', 1));
    expect(
      (await bridge.listAgentRows()).map((r) => r.name),
      'the home server still serves its old copy',
    ).toEqual(['helper']);
    expect((await bridge.listAgentRows({ refresh: true })).map((r) => r.name)).toEqual(['second', 'helper']);
  });
});
