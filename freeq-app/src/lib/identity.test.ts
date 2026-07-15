import { describe, it, expect } from 'vitest';
import { isDid, shortenDid, resolveIdentityName } from './identity';

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
