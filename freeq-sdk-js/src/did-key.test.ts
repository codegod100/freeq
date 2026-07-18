/**
 * Tests for did:key generation + SASL crypto signing.
 *
 * These verify the wire-level invariants the Rust verifier checks:
 *   - did:key string format: `did:key:z<base58btc(0xed01 || pubkey32)>`
 *   - signature is over the raw challenge bytes (not the JSON's nonce)
 *   - signature is base64url(no padding)
 *   - signature verifies against the public key derived from the DID
 *
 * Round-trip-tested for real against a freeq-server in
 * `freeq-server/tests/agent_assist_authenticated.rs`.
 */
import { describe, it, expect } from 'vitest';
import { generateDidKey, importDidKey } from './did-key.js';

describe('generateDidKey', () => {
  it('produces a did:key string with the right shape', async () => {
    const k = await generateDidKey();
    expect(k.did).toMatch(/^did:key:z[1-9A-HJ-NP-Za-km-z]+$/);
    expect(k.publicKeyMultibase).toBe(k.did.slice('did:key:'.length));
  });

  it('did:key starts with z6Mk... for ed25519 (multicodec 0xed01 + 32B)', async () => {
    // base58btc encoding of [0xed, 0x01, ...32 bytes...] always begins
    // with `z6Mk` for ed25519 keys. This is the AT Protocol /
    // did-key-spec convention.
    const k = await generateDidKey();
    expect(k.did.startsWith('did:key:z6Mk')).toBe(true);
  });

  it('signer returns a base64url ed25519 signature that verifies', async () => {
    const k = await generateDidKey();
    const challenge = new TextEncoder().encode(
      JSON.stringify({ session_id: 'test', nonce: 'abc', timestamp: 0 }),
    );
    const sig = await k.signer(challenge);

    // Base64url, no padding, 64-byte signature → 86 chars.
    expect(sig).toMatch(/^[A-Za-z0-9_-]{86}$/);

    // Cross-verify locally by extracting the public key from the DID
    // string and using Web Crypto to verify the signature. This is the
    // same chain the server runs:
    //   - parse `did:key:z…`
    //   - decode multibase to bytes; strip the 0xed01 multicodec prefix
    //   - use the remaining 32 bytes as the ed25519 public key
    //   - verify(message=challenge, signature=base64url-decode(sig))
    const pubBytes = base58btcDecode(k.publicKeyMultibase.slice(1));
    expect(pubBytes[0]).toBe(0xed);
    expect(pubBytes[1]).toBe(0x01);
    const rawPub = pubBytes.slice(2);
    expect(rawPub.length).toBe(32);
    const pubKey = await crypto.subtle.importKey(
      'raw', rawPub, 'Ed25519', false, ['verify'],
    );
    const sigBytes = base64UrlDecode(sig);
    const ok = await crypto.subtle.verify(
      'Ed25519', pubKey, sigBytes, challenge,
    );
    expect(ok, 'signature must verify against the did:key-derived public key').toBe(true);
  });

  it('exportSeed + importDidKey round-trips the same DID', async () => {
    const a = await generateDidKey();
    const seed = await a.exportSeed();
    expect(seed.length).toBe(32);
    const b = await importDidKey(seed);
    expect(b.did).toBe(a.did);

    // And: the imported key signs the same way (same key material,
    // same signatures).
    const challenge = new TextEncoder().encode('round-trip');
    const sigA = await a.signer(challenge);
    const sigB = await b.signer(challenge);
    // Note: ed25519 is deterministic, so signatures of the same input
    // with the same key are byte-identical.
    expect(sigB).toBe(sigA);
  });

  it('importDidKey rejects wrong-length seeds', async () => {
    await expect(importDidKey(new Uint8Array(31))).rejects.toThrow(/32 bytes/);
    await expect(importDidKey(new Uint8Array(33))).rejects.toThrow(/32 bytes/);
  });

  it('two generated DIDs are different', async () => {
    const a = await generateDidKey();
    const b = await generateDidKey();
    expect(b.did).not.toBe(a.did);
  });
});

// ─── helpers used in the test (parallel to did-key.ts internals) ────────

const ALPH = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
function base58btcDecode(s: string): Uint8Array {
  const idx = new Map<string, number>();
  for (let i = 0; i < ALPH.length; i++) idx.set(ALPH[i], i);
  let zeros = 0;
  while (zeros < s.length && s[zeros] === '1') zeros++;
  const bytes: number[] = [];
  for (let i = zeros; i < s.length; i++) {
    const v = idx.get(s[i]);
    if (v === undefined) throw new Error('bad base58 char');
    let carry = v;
    for (let j = 0; j < bytes.length; j++) {
      carry += bytes[j] * 58;
      bytes[j] = carry & 0xff;
      carry >>= 8;
    }
    while (carry > 0) {
      bytes.push(carry & 0xff);
      carry >>= 8;
    }
  }
  const out = new Uint8Array(zeros + bytes.length);
  for (let i = 0; i < bytes.length; i++) out[bytes.length - 1 - i + zeros] = bytes[i];
  return out;
}

function base64UrlDecode(s: string): Uint8Array {
  const padded = s.replace(/-/g, '+').replace(/_/g, '/');
  const pad = (4 - (padded.length % 4)) % 4;
  const bin = atob(padded + '='.repeat(pad));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
