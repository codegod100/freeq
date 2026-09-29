// @vitest-environment jsdom
/**
 * The Agents list: the bots the account says are its own, read from its
 * `at.freeq.agentKey` records, with "+ Add an agent" writing a claim and
 * "Remove" writing its removal, both signed by this device's key.
 *
 * The records are built here with the SDK's own builders and folded by the
 * SDK's own rule, so the rows are read off real signed records.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render, cleanup, screen, fireEvent, waitFor, within } from '@testing-library/react';

const DID = 'did:plc:agentlistowner';
const BROKER = 'https://broker.test.example';

const seam = vi.hoisted(() => ({
  rows: null as unknown,
  pair: null as CryptoKeyPair | null,
  published: true,
  /** The options of each read of the list, in order. */
  reads: [] as unknown[],
}));

vi.mock('../irc/client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../irc/client')>();
  return {
    ...actual,
    // The Devices list reads nothing here.
    listDeviceRows: async () => [],
    listAgentRows: async (options?: { refresh?: boolean }) => {
      seam.reads.push(options);
      return seam.rows;
    },
  };
});

vi.mock('../lib/db', () => ({
  getPreferences: async () => ({ notificationsEnabled: true, soundsEnabled: true }),
  setPreferences: async () => {},
}));

vi.mock('@freeq/sdk', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@freeq/sdk')>();
  return {
    ...actual,
    IndexedDbDeviceKeyStore: class {
      constructor(_did: string) {}
      async load() {
        return seam.pair
          ? {
              keyPair: seam.pair,
              createdAt: THIS_CREATED,
              ...(seam.published ? { recordUri: 'at://this' } : {}),
            }
          : null;
      }
      async save() {}
    },
  };
});

import {
  buildAgentRecord,
  buildAgentRetirement,
  buildDeviceRecord,
  generateDidKey,
  recordKeyOf,
  type AgentKeyRecord,
} from '@freeq/sdk';
import { SettingsPanel } from './SettingsPanel';
import { formatTime } from './MessageList';
import * as client from '../irc/client';
import { useStore } from '../store';

const HOUR_MS = 60 * 60 * 1000;
function hoursAgo(hours: number): string {
  return new Date(Date.now() - hours * HOUR_MS).toISOString();
}
const THIS_CREATED = hoursAgo(240);

let key: Awaited<ReturnType<typeof recordKeyOf>>;
let kid: string;
let device: unknown;

async function botDid(): Promise<string> {
  return (await generateDidKey()).did;
}

beforeEach(async () => {
  const pair = (await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify'])) as CryptoKeyPair;
  key = await recordKeyOf(pair);
  const record = await buildDeviceRecord(key, DID, THIS_CREATED, 'This browser');
  device = record;
  kid = record.kid;
  seam.pair = pair;
  seam.published = true;
  seam.reads = [];
  seam.rows = [];
  localStorage.setItem('freeq-broker-base', BROKER);
  localStorage.setItem('freeq-broker-token', 'BT-TEST');
  client.setSaslCredentials('', DID, '', '');
  useStore.getState().reset();
  useStore.setState({ authDid: DID });
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

const day = (iso: string) =>
  `${new Date(iso).toLocaleDateString([], { month: 'short', day: 'numeric' })}, ${formatTime(new Date(iso))}`;

function panel() {
  return render(<SettingsPanel open onClose={() => {}} />);
}

function rowMeta(name: string): string {
  const row = screen.getByText(name).closest('[data-agent-row]');
  if (!row) throw new Error(`no row for ${name}`);
  return row.querySelector('[data-agent-meta]')!.textContent ?? '';
}

const NOTE =
  "Enter the DID provided by your agent. Adding it writes one note to your account saying it is yours; anyone can check that note.";
const NOT_READY = "To add or remove agents, sign in and publish this device's key first.";
const BAD_DID = 'An agent DID starts with did:, for example did:key:z6Mk…';
const NO_NAME = 'Give the agent a name.';

describe('the Agents list', () => {
  it('shortens a DID to its first 16 characters, an ellipsis and its last 6', () => {
    expect(client.shortDid('did:key:z6MkwVDfCg9LbbY6xjH3EZk8YSFQZujV5Y4y1ZWeER9tDiN3')).toBe(
      'did:key:z6MkwVDf…R9tDiN3'.replace('R9tDiN3', '9tDiN3'),
    );
  });

  it('shows each agent with its DID and date, and Remove on a live one', async () => {
    const [helper, gone] = [await botDid(), await botDid()];
    const [added, removed] = [hoursAgo(48), hoursAgo(2)];
    const records = [
      await buildAgentRecord(key, DID, helper, added, 'helper'),
      await buildAgentRecord(key, DID, gone, hoursAgo(30), 'old bot'),
      await buildAgentRetirement(key, DID, gone, removed),
    ];
    seam.rows = await client.agentRowsFrom(DID, [device], records);
    panel();
    await waitFor(() => screen.getByText('helper'));

    expect(rowMeta('helper')).toBe(`${client.shortDid(helper)} · since ${day(added)}`);
    expect(rowMeta('old bot')).toBe(`${client.shortDid(gone)} · Removed · ${day(removed)}`);
    expect(screen.getAllByRole('button', { name: 'Remove' })).toHaveLength(1);
    expect(screen.getByRole('button', { name: '+ Add an agent' })).toBeTruthy();
    expect(screen.getByText(NOTE)).toBeTruthy();
  });

  it('names an agent with no label by its shortened DID', async () => {
    const bot = await botDid();
    const rows = await client.agentRowsFrom(DID, [device], [
      await buildAgentRecord(key, DID, bot, hoursAgo(5)),
    ]);
    expect(rows.map((r) => r.name)).toEqual([client.shortDid(bot)]);
  });

  it('lists a removed agent for 24 hours after its removal, and at most five', async () => {
    const records: AgentKeyRecord[] = [];
    const bots: string[] = [];
    for (let i = 0; i < 7; i++) {
      const bot = await botDid();
      bots.push(bot);
      records.push(await buildAgentRecord(key, DID, bot, hoursAgo(100), `bot ${i}`));
      // bot 0 was removed 25 hours ago; the rest an hour apart, bot 6 last.
      records.push(await buildAgentRetirement(key, DID, bot, hoursAgo(i === 0 ? 25 : 8 - i)));
    }
    const rows = await client.agentRowsFrom(DID, [device], records);
    expect(rows.map((r) => r.name).sort()).toEqual(['bot 2', 'bot 3', 'bot 4', 'bot 5', 'bot 6']);
    expect(rows.every((r) => r.state === 'removed')).toBe(true);
  });

  it('lists an agent added back after its removal as live, from the new date', async () => {
    const bot = await botDid();
    const again = hoursAgo(3);
    const rows = await client.agentRowsFrom(DID, [device], [
      await buildAgentRecord(key, DID, bot, hoursAgo(50), 'helper'),
      await buildAgentRetirement(key, DID, bot, hoursAgo(20)),
      await buildAgentRecord(key, DID, bot, again, 'helper again'),
    ]);
    expect(rows).toEqual([{ agentDid: bot, name: 'helper again', state: 'active', date: again }]);
  });

  it('dates a bot claimed twice with no removal between by its earlier claim, as the fold does', async () => {
    const bot = await botDid();
    const first = hoursAgo(30);
    const rows = await client.agentRowsFrom(DID, [device], [
      await buildAgentRecord(key, DID, bot, first, 'helper'),
      await buildAgentRecord(key, DID, bot, hoursAgo(5), 'helper twice'),
    ]);
    expect(rows).toEqual([{ agentDid: bot, name: 'helper', state: 'active', date: first }]);
  });
});

/** The broker answering /enroll with `status`, recording every call. */
function broker(status: number, body: unknown = { uri: 'at://x', ok: true }) {
  const calls: { url: string; body: { record: AgentKeyRecord; signer_public_key: string } }[] = [];
  vi.stubGlobal(
    'fetch',
    vi.fn(async (url: string, init?: RequestInit) => {
      calls.push({ url, body: JSON.parse(String(init?.body ?? '{}')) });
      return new Response(JSON.stringify(body), { status });
    }),
  );
  return calls;
}

async function addAgent(did: string, name: string) {
  fireEvent.click(await screen.findByRole('button', { name: '+ Add an agent' }));
  fireEvent.change(screen.getByLabelText('Agent DID'), { target: { value: did } });
  fireEvent.change(screen.getByLabelText('Name'), { target: { value: name } });
  fireEvent.click(screen.getByRole('button', { name: 'Add' }));
}

describe('adding and removing an agent', () => {
  it('writes a claim signed by this device, then reads the list afresh', async () => {
    const calls = broker(200);
    const bot = await botDid();
    panel();
    await addAgent(bot, 'helper');

    await waitFor(() => expect(calls).toHaveLength(1));
    expect(calls[0].url).toBe(`${BROKER}/enroll`);
    const { record, signer_public_key } = calls[0].body;
    expect(record.$type).toBe('at.freeq.agentKey');
    expect(record.did).toBe(DID);
    expect(record.agentDid).toBe(bot);
    expect(record.label).toBe('helper');
    expect(record.kid).toBe(kid);
    expect(record.revokes).toBeUndefined();
    expect(signer_public_key).toBe(key.publicKeyMultibase);
    await waitFor(() => expect(seam.reads).toContainEqual({ refresh: true }));
    // The fields close once the claim is written.
    expect(screen.queryByLabelText('Agent DID')).toBeNull();
  });

  it('reads the stored list then the fresh one on open, and once afresh for each write', async () => {
    const calls = broker(200);
    panel();
    await waitFor(() => expect(seam.reads).toEqual([{ refresh: false }, { refresh: true }]));
    await addAgent(await botDid(), 'helper');
    await waitFor(() => expect(calls).toHaveLength(1));
    await waitFor(() => expect(seam.reads).toHaveLength(3));
    await new Promise((r) => setTimeout(r, 50));
    expect(seam.reads).toEqual([{ refresh: false }, { refresh: true }, { refresh: true }]);
  });

  it('says a DID starts with did: when given a bare key, and writes nothing', async () => {
    const calls = broker(200);
    panel();
    const bare = (await botDid()).slice('did:key:'.length);
    await addAgent(bare, 'helper');
    expect(await screen.findByText(BAD_DID)).toBeTruthy();
    expect(calls).toEqual([]);
    expect(screen.getByLabelText('Agent DID')).toBeTruthy();
  });

  it('says a DID is already used by a live agent, and writes nothing', async () => {
    const calls = broker(200);
    const bot = await botDid();
    seam.rows = await client.agentRowsFrom(DID, [device], [
      await buildAgentRecord(key, DID, bot, hoursAgo(5), 'helper'),
    ]);
    panel();
    await waitFor(() => screen.getByText('helper'));
    await addAgent(bot, 'again');
    expect(await screen.findByText('DID is already in use.')).toBeTruthy();
    expect(calls).toEqual([]);
  });

  it('says a name is already used by a live agent, and writes nothing', async () => {
    const calls = broker(200);
    seam.rows = await client.agentRowsFrom(DID, [device], [
      await buildAgentRecord(key, DID, await botDid(), hoursAgo(5), 'helper'),
    ]);
    panel();
    await waitFor(() => screen.getByText('helper'));
    await addAgent(await botDid(), 'Helper');
    expect(await screen.findByText('Name is already in use.')).toBeTruthy();
    expect(calls).toEqual([]);
  });

  it('asks for a name when none is given, and writes nothing', async () => {
    const calls = broker(200);
    panel();
    await addAgent(await botDid(), '');
    expect(await screen.findByText(NO_NAME)).toBeTruthy();
    expect(calls).toEqual([]);
  });

  it('closes the fields on Cancel and writes nothing', async () => {
    const calls = broker(200);
    panel();
    fireEvent.click(await screen.findByRole('button', { name: '+ Add an agent' }));
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(screen.queryByLabelText('Agent DID')).toBeNull();
    expect(calls).toEqual([]);
  });

  it('asks before removing, then writes the removal dated now', async () => {
    const bot = await botDid();
    seam.rows = await client.agentRowsFrom(DID, [device], [
      await buildAgentRecord(key, DID, bot, hoursAgo(48), 'helper'),
    ]);
    const calls = broker(200);
    panel();
    fireEvent.click(await screen.findByRole('button', { name: 'Remove' }));
    const ask = screen.getByRole('dialog');
    expect(within(ask).getByText('Remove helper from your agents?')).toBeTruthy();
    expect(
      within(ask).getByText('It will no longer be listed as one of yours. Its past messages are unchanged.'),
    ).toBeTruthy();
    fireEvent.click(within(ask).getByRole('button', { name: 'Cancel' }));
    expect(calls).toEqual([]);

    fireEvent.click(screen.getByRole('button', { name: 'Remove' }));
    const before = Date.now();
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Remove' }));
    await waitFor(() => expect(calls).toHaveLength(1));
    const { record } = calls[0].body;
    expect(record.revokes).toBe(bot);
    expect(record.agentDid).toBeUndefined();
    expect(record.kid).toBe(kid);
    expect(Date.parse(record.createdAt)).toBeGreaterThanOrEqual(before - 1000);
    await waitFor(() => expect(seam.reads).toContainEqual({ refresh: true }));
  });

  it("asks for a sign-in and a published key when this device's key is unpublished", async () => {
    seam.published = false;
    const calls = broker(200);
    panel();
    await addAgent(await botDid(), 'helper');
    await waitFor(() => screen.getByText(NOT_READY));
    expect(calls, 'nothing is written').toEqual([]);
  });

  it('says to try again when the claim is not saved', async () => {
    broker(502, 'PDS rejected record');
    panel();
    await addAgent(await botDid(), 'helper');
    await waitFor(() => screen.getByText("Couldn't add helper. Try again."));
  });

  it('says to try again when the removal is not saved', async () => {
    const bot = await botDid();
    seam.rows = await client.agentRowsFrom(DID, [device], [
      await buildAgentRecord(key, DID, bot, hoursAgo(48), 'helper'),
    ]);
    broker(502, 'PDS rejected record');
    panel();
    fireEvent.click(await screen.findByRole('button', { name: 'Remove' }));
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Remove' }));
    await waitFor(() => screen.getByText("Couldn't remove helper. Try again."));
  });

  it('opens the sign-in prompt when the account provider refuses permission', async () => {
    broker(403, { error: 'insufficient_scope' });
    panel();
    await addAgent(await botDid(), 'helper');
    await waitFor(() => screen.getByText('Sign in to continue'));
    expect(
      screen.getByText('Your account needs a fresh sign-in before freeq can change your devices.'),
    ).toBeTruthy();
  });
});
