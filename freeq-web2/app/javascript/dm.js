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
 * Returns the ENC3: wire-format string, or null on failure.
 */
export async function encryptDm(remoteDid, plaintext, serverOrigin) {
  try {
    return await e2ee.encryptMessage(remoteDid, plaintext, serverOrigin);
  } catch (err) {
    console.warn("[dm] encrypt failed:", err);
    return null;
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
export function nickToDid(nick) {
  const lower = nick.toLowerCase();
  const panel = document.getElementById("member-panel");
  if (!panel) return null;

  // Check all joined channels' member panels (via cached channel_members)
  // The member panel for the current channel is in the DOM.
  const members = panel.querySelectorAll(".member");
  for (const el of members) {
    const memberNick = el.querySelector(".nick")?.textContent?.trim();
    if (memberNick && memberNick.toLowerCase() === lower) {
      const did = el.dataset.did;
      if (did) return did;
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

/** Get the server origin for E2EE API calls (pre-key bundle fetch/upload). */
export function getServerOrigin() {
  // The upstream REST API base — same as FREEQ_UPSTREAM_REST on the server.
  // For the browser, we use the same origin as the page (the BFF proxies).
  return window.location.origin;
}
