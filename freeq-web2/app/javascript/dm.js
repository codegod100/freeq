/**
 * DM (Direct Message) support for freeq-web2.
 *
 * Uses @freeq/sdk's E2EE module for browser-side Double Ratchet encryption.
 * The Rails server only relays ciphertext — it never sees plaintext.
 *
 * Wire format: ENC3:<header>:<nonce>:<ciphertext> (Double Ratchet)
 *
 * The DM list is persisted in localStorage; E2EE sessions in IndexedDB
 * (managed by the SDK).
 */

import * as e2ee from "@freeq/sdk/e2ee";

const DM_LIST_KEY = "freeq-dm-list";
// Survives refresh so our own ENC3 rows stay readable. DR only decrypts the
// *partner's* send chain; outbound ciphertext is not round-trippable.
const ECHO_STORAGE_KEY = "freeq-dm-echo-v1";
const ECHO_MAX = 200;
const ECHO_TTL_MS = 7 * 24 * 60 * 60 * 1000;

// Ciphertext → plaintext for our own outbound DMs (in-memory + localStorage).
const echoPlaintext = new Map();

function loadEchoStore() {
  try {
    const raw = localStorage.getItem(ECHO_STORAGE_KEY);
    if (!raw) return;
    const obj = JSON.parse(raw);
    const now = Date.now();
    for (const [wire, entry] of Object.entries(obj)) {
      if (!entry || typeof entry.p !== "string") continue;
      if (now - (entry.t || 0) > ECHO_TTL_MS) continue;
      echoPlaintext.set(wire, entry.p);
    }
  } catch {
    // ignore corrupt storage
  }
}

function persistEchoStore() {
  try {
    const now = Date.now();
    // Drop expired / over-cap entries (oldest first).
    const entries = [...echoPlaintext.entries()];
    while (entries.length > ECHO_MAX) {
      const [old] = entries.shift();
      echoPlaintext.delete(old);
    }
    const obj = {};
    for (const [wire, p] of echoPlaintext) {
      obj[wire] = { p, t: now };
    }
    localStorage.setItem(ECHO_STORAGE_KEY, JSON.stringify(obj));
  } catch {
    // quota / private mode — in-memory still works for the session
  }
}

// Hydrate on module load so refresh can restore own messages immediately.
loadEchoStore();

/** Remember plaintext for a wire ENC3: body we just encrypted. */
export function cacheEcho(wire, plaintext) {
  if (wire && plaintext != null) {
    echoPlaintext.set(wire, plaintext);
    persistEchoStore();
  }
}

/** Look up cached plaintext for an outbound ENC3 body. */
export function getEcho(wire) {
  return echoPlaintext.get(wire) || null;
}

// ── DM list persistence ──

/** Load the persisted DM list (array of nicks). */
export function loadDmList() {
  try {
    const raw = localStorage.getItem(DM_LIST_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

/** Save the DM list. */
function saveDmList(dms) {
  try {
    localStorage.setItem(DM_LIST_KEY, JSON.stringify(dms));
  } catch {
    // localStorage may be full or disabled — non-fatal
  }
}

/** Add a nick to the DM list if not already present. */
export function addDm(nick) {
  const dms = loadDmList();
  const lower = nick.toLowerCase();
  if (!dms.some((d) => d.toLowerCase() === lower)) {
    dms.push(nick);
    saveDmList(dms);
  }
}

/** Remove a nick from the DM list. */
export function removeDm(nick) {
  const lower = nick.toLowerCase();
  const dms = loadDmList().filter((d) => d.toLowerCase() !== lower);
  saveDmList(dms);
}

// ── E2EE ──

/**
 * Initialize E2EE for the authenticated user.
 * Generates identity keys, uploads pre-key bundle to the server.
 * Called after SASL authentication succeeds.
 */
export async function initE2ee(did, serverOrigin) {
  if (!did || !serverOrigin) return;
  try {
    await e2ee.initialize(did, serverOrigin);
    console.log("[dm] E2EE initialized for", did);
  } catch (err) {
    console.warn("[dm] E2EE init failed:", err);
  }
}

/** Check if E2EE is ready (identity keys generated, pre-key uploaded). */
export function isE2eeReady() {
  return e2ee.isE2eeReady();
}

/** Check if a DM session exists with the given DID. */
export function hasDmSession(did) {
  return e2ee.hasSession(did);
}

/**
 * Encrypt a DM message for the given remote DID.
 * Returns `{ ok: wire }` or `{ error: "no_prekey" | "encrypt_failed", message }`.
 */
export async function encryptDm(remoteDid, plaintext, serverOrigin) {
  try {
    const wire = await e2ee.encryptMessage(remoteDid, plaintext, serverOrigin);
    if (wire) return { ok: wire };

    // encryptMessage returns null when the remote pre-key is missing (or
    // session setup failed). Distinguish the common "they never published
    // keys" case so the UI can show an actionable message.
    const hasKey =
      typeof e2ee.hasRemotePreKey === "function"
        ? await e2ee.hasRemotePreKey(remoteDid, serverOrigin)
        : false;
    if (!hasKey) {
      return {
        error: "no_prekey",
        message:
          "Cannot encrypt — recipient has not published encryption keys yet. Ask them to open freeq while signed in (any client), then try again.",
      };
    }
    return { error: "encrypt_failed", message: "Encryption failed" };
  } catch (err) {
    console.warn("[dm] encrypt failed:", err);
    return { error: "encrypt_failed", message: "Encryption failed" };
  }
}

/**
 * Decrypt a DM message from the given remote DID.
 * Returns the plaintext string, or null on failure.
 */
export async function decryptDm(remoteDid, wire, serverOrigin) {
  try {
    return await e2ee.decryptMessage(remoteDid, wire, serverOrigin);
  } catch (err) {
    console.warn("[dm] decrypt failed:", err);
    return null;
  }
}

/** Check if a message body is an encrypted DM (ENC3 prefix). */
export function isEncryptedDm(text) {
  return e2ee.isEncrypted(text);
}

/** Get the safety number for a DM partner (for verification). */
export async function getSafetyNumber(remoteDid) {
  try {
    return await e2ee.getSafetyNumber(remoteDid);
  } catch {
    return null;
  }
}

// ── Nick → DID resolution ──

/**
 * Resolve a nick to a DID using the member panel data.
 * Member rows carry data-did attributes when the user is authenticated.
 */
/**
 * Resolve a nick to a DID using the DOM (member panel + message rows).
 * Synchronous — returns null if not found in the DOM.
 */
export function nickToDid(nick) {
  const lower = nick.toLowerCase();
  const panel = document.getElementById("member-panel");
  if (panel) {
    const members = panel.querySelectorAll(".member");
    for (const el of members) {
      const memberNick = el.querySelector(".nick")?.textContent?.trim();
      if (memberNick && memberNick.toLowerCase() === lower) {
        const did = el.dataset.did;
        if (did) return did;
      }
    }
  }

  // Also check message rows — the account tag carries the sender's DID
  const msgs = document.querySelectorAll(
    `#messages .msg[data-nick="${CSS.escape(nick)}"]`
  );
  for (const el of msgs) {
    const did = el.dataset.account || el.dataset.did;
    if (did) return did;
  }

  return null;
}

export async function nickToDidAsync(nick) {
  // Fast path: check the DOM (member panel + message rows).
  const domDid = nickToDid(nick);
  if (domDid) return domDid;

  // Slow path: ask the server (cached nick→DID map, or WHOIS).
  try {
    const resp = await fetch(`/api/did/${encodeURIComponent(nick)}`, {
      headers: { Accept: "application/json" },
    });
    if (resp.ok) {
      const data = await resp.json();
      if (data.did) return data.did;
    }
  } catch (err) {
    console.warn("[dm] nickToDidAsync fetch failed:", err);
  }
  return null;
}

/** Get the server origin for E2EE API calls (pre-key bundle fetch/upload). */
export function getServerOrigin() {
  // The upstream REST API base — same as FREEQ_UPSTREAM_REST on the server.
  // For the browser, we use the same origin as the page (the BFF proxies).
  return window.location.origin;
}
