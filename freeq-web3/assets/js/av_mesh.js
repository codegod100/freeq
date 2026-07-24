/**
 * AV call mesh: canonical broadcast names and participant subscription set.
 * Ported from freeq-app/src/lib/av-mesh.ts / freeq-web2 av/mesh.js.
 */

export function broadcastName(sessionId, nick, instance) {
  return instance ? `${sessionId}/${nick}~${instance}` : `${sessionId}/${nick}`;
}

function broadcastKey(nick, instance) {
  return instance ? `${nick}~${instance}` : nick;
}

function isSelf(p, me) {
  if (me.instance || p.instance_id) {
    return !!me.instance && p.instance_id === me.instance;
  }
  if (me.did || p.did) {
    return !!me.did && p.did === me.did;
  }
  return String(p.nick || "").toLowerCase() === String(me.nick || "").toLowerCase();
}

export function computeParticipantSlots(participants, me, sessionId) {
  return (participants || [])
    .filter((p) => !isSelf(p, me))
    .map((p) => ({
      nick: p.nick,
      broadcastKey: broadcastKey(p.nick, p.instance_id),
      broadcastName: broadcastName(sessionId, p.nick, p.instance_id),
    }));
}
