import { describe, it, expect } from 'vitest';
import { isDid, shortenDid, resolveIdentityName, findMemberByKey } from './identity';

describe('isDid', () => {
  it('recognizes DIDs and rejects nicks / partials', () => {
    expect(isDid('did:plc:k2n3e2vsihf3farequ44t5j7')).toBe(true);
    expect(isDid('did:key:z6MkabcDEF')).toBe(true);
    expect(isDid('alice')).toBe(false);
    expect(isDid('did:plc:')).toBe(false);
  });
});

describe('shortenDid', () => {
  it('compacts a long DID head+tail; passes nicks through', () => {
    expect(shortenDid('did:plc:k2n3e2vsihf3farequ44t5j7')).toBe('plc:k2n3…t5j7');
    expect(shortenDid('bob')).toBe('bob');
  });
});

describe('resolveIdentityName', () => {
  const did = 'did:plc:k2n3e2vsihf3farequ44t5j7';

  it('returns a plain nick unchanged', () => {
    expect(resolveIdentityName('alice')).toBe('alice');
  });

  it('resolves a DID via the nick map first', () => {
    expect(resolveIdentityName(did, { nickForDid: () => 'alice' })).toBe('alice');
  });

  it('falls to the profile name when no nick is known', () => {
    expect(
      resolveIdentityName(did, { nickForDid: () => undefined, nameForDid: () => 'Alice R.' }),
    ).toBe('Alice R.');
  });

  it('skips DID-valued sources and compacts as the last resort', () => {
    expect(
      resolveIdentityName(did, { nickForDid: () => 'did:plc:other', nameForDid: () => null }),
    ).toBe('plc:k2n3…t5j7');
  });

  it('compacts when there are no sources at all', () => {
    expect(resolveIdentityName(did)).toBe('plc:k2n3…t5j7');
  });
});

describe('findMemberByKey', () => {
  const bot = { did: 'did:key:z6MkBot', away: null };
  const carol = { did: undefined, away: 'lunch' };
  const channels = new Map([
    ['#dev', { members: new Map([['didtestbot', bot], ['carol', carol]]) }],
    // A DM buffer keyed by the peer's DID, holding its own member record.
    ['did:key:z6mkbot', { members: new Map([['didtestbot', bot]]) }],
  ]);

  it('finds a peer by DID — the case a nick-keyed lookup misses', () => {
    expect(findMemberByKey(channels, 'did:key:z6MkBot')?.nick).toBe('didtestbot');
  });

  it('finds a peer by nick, case-insensitively', () => {
    expect(findMemberByKey(channels, 'DidTestBot')?.nick).toBe('didtestbot');
    expect(findMemberByKey(channels, 'carol')?.member.away).toBe('lunch');
  });

  it('returns null for an unknown peer', () => {
    expect(findMemberByKey(channels, 'did:plc:nobody')).toBeNull();
    expect(findMemberByKey(channels, 'nobody')).toBeNull();
  });

  it('channelsOnly ignores DM buffers so they cannot answer for themselves', () => {
    const dmOnly = new Map([
      ['did:key:z6mkbot', { members: new Map([['didtestbot', bot]]) }],
    ]);
    expect(findMemberByKey(dmOnly, 'did:key:z6MkBot', true)).toBeNull();
    expect(findMemberByKey(dmOnly, 'did:key:z6MkBot', false)?.nick).toBe('didtestbot');
  });
});
