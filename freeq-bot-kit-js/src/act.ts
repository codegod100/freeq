// Signing and verification for `freeq.at/act` action messages.
//
// Implements the act canonical from the act RFC (docs/HANDOFF-RFC.md, v0.4):
// the signature covers every `act-*` tag present on the message — not a
// fixed field list — JCS-canonicalized with sorted keys. Must stay
// byte-compatible with `freeq_sdk::act` on the Rust side; the shared
// contract is `spec/act-signing-vectors.json`, which both test suites
// reproduce exactly.
//
// Canonical mapping rules (see the Rust module for the full rationale):
// - covered iff the tag name, after stripping `+freeq.at/`, is `act` or
//   starts with `act-` (`actor-class` and `sig` are NOT covered)
// - canonical keys are the stripped names; values verbatim, always strings
// - sig tag value: `ed25519:<kid>:<base64url sig>`, kid =
//   base64url-nopad(sha256(raw 32-byte public key)[0..16])

import type { DidKey } from "@freeq/sdk";
import { canonicalizeForSigning } from "./delegation.js";

/** Wire name of the signature tag (also accepted without the `+`). */
export const ACT_SIG_TAG = "+freeq.at/sig";

const CLIENT_TAG_PREFIX = "+freeq.at/";
const TAG_PREFIX = "freeq.at/";

export type ActVerifyResult =
  | { ok: true }
  | {
      ok: false;
      reason:
        | "no-act-tags"
        | "bad-sig-format"
        | "unsupported-algorithm"
        | "kid-mismatch"
        | "sig-invalid";
    };

function strippedName(tagName: string): string {
  if (tagName.startsWith(CLIENT_TAG_PREFIX)) return tagName.slice(CLIENT_TAG_PREFIX.length);
  if (tagName.startsWith(TAG_PREFIX)) return tagName.slice(TAG_PREFIX.length);
  return tagName;
}

function isActTag(tagName: string): boolean {
  const name = strippedName(tagName);
  return name === "act" || name.startsWith("act-");
}

/**
 * Build the canonical string over the act tags in `tags` (wire names,
 * unescaped values). Returns null if no act tags are present.
 */
export function actCanonical(tags: Record<string, string>): string | null {
  const covered: Record<string, string> = {};
  for (const [name, value] of Object.entries(tags)) {
    if (isActTag(name)) covered[strippedName(name)] = value;
  }
  if (Object.keys(covered).length === 0) return null;
  return canonicalizeForSigning(covered);
}

/** base64url (unpadded) of the first 16 bytes of SHA-256 over the raw key. */
export async function deriveKid(rawPublicKey: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", rawPublicKey));
  return b64url(digest.slice(0, 16));
}

/**
 * Sign the act tags with a DidKey. Returns the sig tag value
 * (`ed25519:<kid>:<base64url sig>`), or null if no act tags are present.
 */
export async function signActTags(
  tags: Record<string, string>,
  key: DidKey,
): Promise<string | null> {
  const canonical = actCanonical(tags);
  if (canonical === null) return null;
  const sig = await key.signer(new TextEncoder().encode(canonical));
  const kid = await deriveKid(publicKeyFromMultibase(key.publicKeyMultibase));
  return `ed25519:${kid}:${sig}`;
}

/** Verify an act sig tag over `tags` against a raw 32-byte public key. */
export async function verifyActTags(
  tags: Record<string, string>,
  sigTag: string,
  rawPublicKey: Uint8Array,
): Promise<ActVerifyResult> {
  const parts = sigTag.split(":");
  if (parts.length !== 3) return { ok: false, reason: "bad-sig-format" };
  const [alg, kid, sigB64] = parts;
  if (alg !== "ed25519") return { ok: false, reason: "unsupported-algorithm" };
  if ((await deriveKid(rawPublicKey)) !== kid) return { ok: false, reason: "kid-mismatch" };
  const canonical = actCanonical(tags);
  if (canonical === null) return { ok: false, reason: "no-act-tags" };
  let sig: Uint8Array;
  try {
    sig = b64urlDecode(sigB64);
  } catch {
    return { ok: false, reason: "bad-sig-format" };
  }
  const cryptoKey = await crypto.subtle.importKey("raw", rawPublicKey, "Ed25519", false, [
    "verify",
  ]);
  const valid = await crypto.subtle.verify(
    "Ed25519",
    cryptoKey,
    sig,
    new TextEncoder().encode(canonical),
  );
  return valid ? { ok: true } : { ok: false, reason: "sig-invalid" };
}

/**
 * Decode a `z…` ed25519 multibase public key (the part of a did:key after
 * `did:key:`) to its raw 32 bytes.
 */
export function publicKeyFromMultibase(multibase: string): Uint8Array {
  if (!multibase.startsWith("z")) {
    throw new Error(`expected base58btc multibase (z…), got ${multibase.slice(0, 4)}…`);
  }
  const bytes = base58btcDecode(multibase.slice(1));
  // Strip the 0xed01 ed25519 multicodec prefix.
  if (bytes.length !== 34 || bytes[0] !== 0xed || bytes[1] !== 0x01) {
    throw new Error("not an ed25519 multicodec key");
  }
  return bytes.slice(2);
}

const B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

function base58btcDecode(s: string): Uint8Array {
  const bytes: number[] = [0];
  for (const c of s) {
    const digit = B58_ALPHABET.indexOf(c);
    if (digit < 0) throw new Error(`invalid base58 character ${c}`);
    let carry = digit;
    for (let i = 0; i < bytes.length; i++) {
      const x = bytes[i] * 58 + carry;
      bytes[i] = x & 0xff;
      carry = x >> 8;
    }
    while (carry > 0) {
      bytes.push(carry & 0xff);
      carry >>= 8;
    }
  }
  // Leading '1's are leading zero bytes.
  for (const c of s) {
    if (c !== "1") break;
    bytes.push(0);
  }
  return new Uint8Array(bytes.reverse());
}

function b64url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

function b64urlDecode(s: string): Uint8Array {
  return new Uint8Array(Buffer.from(s, "base64url"));
}
