import { describe, it, expect } from 'vitest';
import { isDid, dmPeerKey } from './address.js';

describe('isDid', () => {
  it('recognizes DIDs and rejects nicks / partials', () => {
    expect(isDid('did:plc:k2n3e2vsihf3farequ44t5j7')).toBe(true);
    expect(isDid('did:key:z6MkabcDEF')).toBe(true);
    expect(isDid('did:web:example.com')).toBe(true);
    expect(isDid('alice')).toBe(false);
    expect(isDid('did:')).toBe(false);
    expect(isDid('did:plc:')).toBe(false);
    expect(isDid('#did:plc:x')).toBe(false);
  });
});

describe('dmPeerKey', () => {
  // The one rule applied to a DM peer everywhere it is referenced (wire
  // target + local thread key): DID when known, else the input unchanged.
  const resolver = (nick: string): string | undefined =>
    ({ bob: 'did:plc:bob', alice: 'did:plc:alice' })[nick.toLowerCase()];

  it('passes a DID through unchanged (idempotent — DID in, same DID out)', () => {
    expect(dmPeerKey('did:plc:bob', resolver)).toBe('did:plc:bob');
    // Idempotent even when the DID also has a nick mapped to it.
    expect(dmPeerKey(dmPeerKey('bob', resolver), resolver)).toBe('did:plc:bob');
  });

  it('resolves a known nick to its DID so nick and DID collapse to one key', () => {
    expect(dmPeerKey('bob', resolver)).toBe('did:plc:bob');
    expect(dmPeerKey('bob', resolver)).toBe(dmPeerKey('did:plc:bob', resolver));
  });

  it('leaves an unknown nick (guest / unresolved / remote) unchanged', () => {
    expect(dmPeerKey('carol', resolver)).toBe('carol');
  });

  it('does not lowercase or otherwise mangle a nick it cannot resolve', () => {
    expect(dmPeerKey('Carol', resolver)).toBe('Carol');
  });
});
