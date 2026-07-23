/**
 * AV call mesh: who subscribes to whom.
 *
 * Port of freeq-app/src/lib/av-mesh.ts — single source of truth for MoQ
 * broadcast paths so publish and subscribe can never drift.
 */

/** Canonical MoQ path: `{sessionId}/{nick}~{instance}` (or bare nick). */
export function broadcastName(sessionId, nick, instance) {
  return instance ? `${sessionId}/${nick}~${instance}` : `${sessionId}/${nick}`;
}

function broadcastKey(nick, instance) {
  return instance ? `${nick}~${instance}` : nick;
}

/**
 * Identity is NEVER decided by nick alone — instance first, then DID,
 * nick only as a last resort (legacy rows).
 */
function isSelf(p, me) {
  if (me.instance || p.instance_id) {
    return !!me.instance && p.instance_id === me.instance;
  }
  if (me.did || p.did) {
    return !!me.did && p.did === me.did;
  }
  return String(p.nick || "").toLowerCase() === String(me.nick || "").toLowerCase();
}

/**
 * Subscribe set: one slot per *other* live participant.
 * @param {Array<{did?: string, nick: string, instance_id?: string}>} participants
 * @param {{nick: string, instance: string|null, did?: string|null}} me
 * @param {string} sessionId
 */
export function computeParticipantSlots(participants, me, sessionId) {
  return (participants || [])
    .filter((p) => !isSelf(p, me))
    .map((p) => ({
      nick: p.nick,
      broadcastKey: broadcastKey(p.nick, p.instance_id),
      broadcastName: broadcastName(sessionId, p.nick, p.instance_id),
    }));
}
