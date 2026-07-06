/** Unit tests for delegation.ts. */
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm, readFile, writeFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  buildDelegation,
  canonicalizeForSigning,
  loadDelegation,
  loadOrMintDelegation,
  signDelegation,
  type DelegationCert,
} from "./delegation.js";
import { generateDidKey } from "@freeq/sdk";

const FAKE_AGENT_DID = "did:key:zABCDEFGHIJKLMNOPQRSTUVWXYZ";
const FAKE_OWNER_DID = "did:plc:xyzowner";

/** Verify a cert's ed25519 signature the way the server does:
 *  JCS-canonical form with `signature` removed, base64url signature,
 *  creator's raw public key. */
async function verifyLikeServer(
  cert: DelegationCert,
  rawPublicKey: Uint8Array,
): Promise<boolean> {
  if (!cert.signature) return false;
  const { signature, ...unsigned } = cert;
  const canonical = canonicalizeForSigning(unsigned);
  const b64 = signature.replace(/-/g, "+").replace(/_/g, "/");
  const sigBytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "raw",
    rawPublicKey as BufferSource,
    { name: "Ed25519" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify(
    "Ed25519",
    key,
    sigBytes as BufferSource,
    new TextEncoder().encode(canonical) as BufferSource,
  );
}

/** Extract the raw 32-byte ed25519 public key from a did:key multibase
 *  (z-base58btc, 0xed01 multicodec prefix). Minimal decoder for tests. */
function rawPubFromMultibase(multibase: string): Uint8Array {
  const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  let n = 0n;
  for (const ch of multibase.slice(1)) {
    n = n * 58n + BigInt(ALPHABET.indexOf(ch));
  }
  const bytes: number[] = [];
  while (n > 0n) {
    bytes.unshift(Number(n & 0xffn));
    n >>= 8n;
  }
  // Strip the 0xed 0x01 multicodec prefix.
  return new Uint8Array(bytes.slice(2));
}

describe("buildDelegation", () => {
  it("emits a v1 cert with expected fields", () => {
    const cert = buildDelegation({ agentDid: FAKE_AGENT_DID, ownerDid: FAKE_OWNER_DID });
    expect(cert.type).toBe("FreeqBotDelegation/v1");
    expect(cert.bot_did).toBe(FAKE_AGENT_DID);
    expect(cert.bot_public_key).toBe("zABCDEFGHIJKLMNOPQRSTUVWXYZ");
    expect(cert.creator_did).toBe(FAKE_OWNER_DID);
    expect(cert.revocation_authority).toBe(FAKE_OWNER_DID);
    expect(cert.signature).toBeNull();
    expect(new Date(cert.created_at).toString()).not.toBe("Invalid Date");
  });

  it("rejects an agentDid without did:key: prefix", () => {
    expect(() =>
      buildDelegation({ agentDid: "did:plc:notakey", ownerDid: FAKE_OWNER_DID }),
    ).toThrow(/did:key/);
  });
});

describe("loadDelegation", () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "freeq-bot-kit-delegation-"));
  });
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("returns null when the file is absent", async () => {
    const result = await loadDelegation({ certPath: join(dir, "nope.json") });
    expect(result).toBeNull();
  });

  it("parses a well-formed cert", async () => {
    const certPath = join(dir, "delegation.json");
    const cert: DelegationCert = {
      type: "FreeqBotDelegation/v1",
      bot_did: FAKE_AGENT_DID,
      bot_public_key: "zABCDEFGHIJKLMNOPQRSTUVWXYZ",
      creator_did: FAKE_OWNER_DID,
      created_at: "2025-01-01T00:00:00.000Z",
      revocation_authority: FAKE_OWNER_DID,
      signature: null,
    };
    await writeFile(certPath, JSON.stringify(cert));
    const loaded = await loadDelegation({ certPath });
    expect(loaded).toEqual(cert);
  });

  it("rejects malformed JSON", async () => {
    const certPath = join(dir, "delegation.json");
    await writeFile(certPath, "{not json");
    await expect(loadDelegation({ certPath })).rejects.toThrow(/not valid JSON/);
  });

  it("rejects an unknown type tag", async () => {
    const certPath = join(dir, "delegation.json");
    await writeFile(certPath, JSON.stringify({ type: "SomethingElse/v9" }));
    await expect(loadDelegation({ certPath })).rejects.toThrow(/expected FreeqBotDelegation/);
  });
});

describe("loadOrMintDelegation", () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "freeq-bot-kit-delegation-"));
  });
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("mints a fresh cert when none exists", async () => {
    const certPath = join(dir, "delegation.json");
    const cert = await loadOrMintDelegation({
      certPath,
      agentDid: FAKE_AGENT_DID,
      ownerDid: FAKE_OWNER_DID,
    });
    expect(cert.bot_did).toBe(FAKE_AGENT_DID);
    expect(cert.creator_did).toBe(FAKE_OWNER_DID);

    // Was persisted.
    const onDisk = JSON.parse(await readFile(certPath, "utf8"));
    expect(onDisk.bot_did).toBe(FAKE_AGENT_DID);
  });

  it("returns the existing cert when one is on disk and matches", async () => {
    const certPath = join(dir, "delegation.json");
    const first = await loadOrMintDelegation({
      certPath,
      agentDid: FAKE_AGENT_DID,
      ownerDid: FAKE_OWNER_DID,
    });
    const second = await loadOrMintDelegation({
      certPath,
      agentDid: FAKE_AGENT_DID,
      ownerDid: FAKE_OWNER_DID,
    });
    expect(second.created_at).toBe(first.created_at); // same instance loaded back
  });

  it("throws when the existing cert names a different agentDid", async () => {
    const certPath = join(dir, "delegation.json");
    await loadOrMintDelegation({
      certPath,
      agentDid: FAKE_AGENT_DID,
      ownerDid: FAKE_OWNER_DID,
    });
    await expect(
      loadOrMintDelegation({
        certPath,
        agentDid: "did:key:zDIFFERENT",
        ownerDid: FAKE_OWNER_DID,
      }),
    ).rejects.toThrow(/bot_did/);
  });

  it("throws when the existing cert names a different ownerDid", async () => {
    const certPath = join(dir, "delegation.json");
    await loadOrMintDelegation({
      certPath,
      agentDid: FAKE_AGENT_DID,
      ownerDid: FAKE_OWNER_DID,
    });
    await expect(
      loadOrMintDelegation({
        certPath,
        agentDid: FAKE_AGENT_DID,
        ownerDid: "did:plc:somebody-else",
      }),
    ).rejects.toThrow(/creator_did/);
  });

  it("creates parent directories if needed", async () => {
    const certPath = join(dir, "nested", "deep", "delegation.json");
    await loadOrMintDelegation({
      certPath,
      agentDid: FAKE_AGENT_DID,
      ownerDid: FAKE_OWNER_DID,
    });
    const s = await stat(certPath);
    expect(s.isFile()).toBe(true);
  });

  it("writes the cert with mode 0600", async () => {
    const certPath = join(dir, "delegation.json");
    await loadOrMintDelegation({
      certPath,
      agentDid: FAKE_AGENT_DID,
      ownerDid: FAKE_OWNER_DID,
    });
    const s = await stat(certPath);
    if (process.platform === "linux" || process.platform === "darwin") {
      expect(s.mode & 0o777).toBe(0o600);
    }
  });
});

describe("canonicalizeForSigning", () => {
  it("sorts keys and emits compact JSON", () => {
    expect(canonicalizeForSigning({ b: "2", a: "1" })).toBe('{"a":"1","b":"2"}');
    expect(canonicalizeForSigning({ x: null, y: true, z: 3 })).toBe(
      '{"x":null,"y":true,"z":3}',
    );
    expect(canonicalizeForSigning(["b", "a"])).toBe('["b","a"]');
  });

  it("omits undefined values and rejects floats", () => {
    expect(canonicalizeForSigning({ a: "1", gone: undefined })).toBe('{"a":"1"}');
    expect(() => canonicalizeForSigning({ f: 1.5 })).toThrow(/non-integer/);
  });

  it("matches the JCS form the Rust verifier reproduces for a real cert", () => {
    const cert = {
      type: "FreeqBotDelegation/v1",
      bot_did: "did:key:zBot",
      bot_public_key: "zBot",
      creator_did: "did:plc:owner",
      created_at: "2026-01-01T00:00:00.000Z",
      revocation_authority: "did:plc:owner",
    };
    // Keys sorted by code unit — the exact byte layout the server's
    // freeq_sdk::canonical::canonicalize produces.
    expect(canonicalizeForSigning(cert)).toBe(
      '{"bot_did":"did:key:zBot","bot_public_key":"zBot",' +
        '"created_at":"2026-01-01T00:00:00.000Z","creator_did":"did:plc:owner",' +
        '"revocation_authority":"did:plc:owner","type":"FreeqBotDelegation/v1"}',
    );
  });
});

describe("signDelegation", () => {
  it("produces a signature the server-side algorithm accepts", async () => {
    const creator = await generateDidKey();
    const seed = await creator.exportSeed();
    const cert = buildDelegation({ agentDid: FAKE_AGENT_DID, ownerDid: FAKE_OWNER_DID });

    const signed = await signDelegation(cert, seed);
    expect(signed.signature).toBeTruthy();

    const rawPub = rawPubFromMultibase(creator.publicKeyMultibase);
    expect(rawPub.length).toBe(32);
    expect(await verifyLikeServer(signed, rawPub)).toBe(true);
  });

  it("a tampered cert no longer verifies", async () => {
    const creator = await generateDidKey();
    const seed = await creator.exportSeed();
    const cert = buildDelegation({ agentDid: FAKE_AGENT_DID, ownerDid: FAKE_OWNER_DID });
    const signed = await signDelegation(cert, seed);

    const tampered = { ...signed, creator_did: "did:plc:mallory" };
    const rawPub = rawPubFromMultibase(creator.publicKeyMultibase);
    expect(await verifyLikeServer(tampered, rawPub)).toBe(false);
  });

  it("a different key's signature does not verify", async () => {
    const creator = await generateDidKey();
    const other = await generateDidKey();
    const cert = buildDelegation({ agentDid: FAKE_AGENT_DID, ownerDid: FAKE_OWNER_DID });
    const signed = await signDelegation(cert, await other.exportSeed());
    const rawPub = rawPubFromMultibase(creator.publicKeyMultibase);
    expect(await verifyLikeServer(signed, rawPub)).toBe(false);
  });
});

describe("loadOrMintDelegation with creatorKeyPath", () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "freeq-bot-kit-delegation-sign-"));
  });
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("mints a SIGNED cert when a creator key is provided", async () => {
    const creator = await generateDidKey();
    const keyPath = join(dir, "creator.key");
    await writeFile(keyPath, await creator.exportSeed(), { mode: 0o600 });

    const cert = await loadOrMintDelegation({
      certPath: join(dir, "delegation.json"),
      agentDid: FAKE_AGENT_DID,
      ownerDid: FAKE_OWNER_DID,
      creatorKeyPath: keyPath,
    });
    expect(cert.signature).toBeTruthy();
    const rawPub = rawPubFromMultibase(creator.publicKeyMultibase);
    expect(await verifyLikeServer(cert, rawPub)).toBe(true);
  });

  it("upgrades an existing unsigned cert in place", async () => {
    const certPath = join(dir, "delegation.json");
    const unsigned = await loadOrMintDelegation({
      certPath,
      agentDid: FAKE_AGENT_DID,
      ownerDid: FAKE_OWNER_DID,
    });
    expect(unsigned.signature).toBeNull();

    const creator = await generateDidKey();
    const keyPath = join(dir, "creator.key");
    await writeFile(keyPath, await creator.exportSeed(), { mode: 0o600 });

    const upgraded = await loadOrMintDelegation({
      certPath,
      agentDid: FAKE_AGENT_DID,
      ownerDid: FAKE_OWNER_DID,
      creatorKeyPath: keyPath,
    });
    expect(upgraded.signature).toBeTruthy();

    // The upgrade persisted — reloading without a key returns the signed cert.
    const reloaded = await loadDelegation({ certPath });
    expect(reloaded?.signature).toBe(upgraded.signature);
  });

  it("rejects a creator key of the wrong size", async () => {
    const keyPath = join(dir, "creator.key");
    await writeFile(keyPath, new Uint8Array(16), { mode: 0o600 });
    await expect(
      loadOrMintDelegation({
        certPath: join(dir, "delegation.json"),
        agentDid: FAKE_AGENT_DID,
        ownerDid: FAKE_OWNER_DID,
        creatorKeyPath: keyPath,
      }),
    ).rejects.toThrow(/expected 32/);
  });
});
