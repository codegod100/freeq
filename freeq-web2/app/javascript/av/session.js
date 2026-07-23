/**
 * AV session control plane — discover/start/join/leave via freeq-web2 API
 * (which enqueues IRC TAGMSG on the BFF upstream WS).
 */

let currentInstance = null;
const startInFlight = new Set();

/** 8 lowercase hex chars — per-device, per-call instance suffix. */
export function generateAvInstanceId() {
  const bytes = new Uint8Array(4);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export function getAvInstanceId() {
  return currentInstance;
}

export function setAvInstanceId(id) {
  currentInstance = id || null;
}

function csrfToken() {
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta?.getAttribute("content") || "";
}

async function postJson(path, body) {
  const resp = await fetch(path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
      "X-CSRF-Token": csrfToken(),
    },
    credentials: "same-origin",
    body: JSON.stringify(body),
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    const err = new Error(data.error || `HTTP ${resp.status}`);
    err.status = resp.status;
    err.data = data;
    throw err;
  }
  return data;
}

/**
 * Discover active session on a channel, or start a new one.
 * Returns { sessionId, instance, joinedExisting }.
 * Caller should open the call panel and wait for av-state / roster poll
 * when starting fresh (sessionId may be null until REST converges).
 */
export async function startOrJoinAvSession(channel) {
  const key = String(channel || "").toLowerCase();
  if (!key) throw new Error("channel required");
  if (startInFlight.has(key)) return null;
  startInFlight.add(key);

  try {
    // Discover existing active session first.
    try {
      const resp = await fetch(
        `/api/v1/channels/${encodeURIComponent(channel)}/sessions`,
        { credentials: "same-origin" }
      );
      if (resp.ok) {
        const data = await resp.json();
        const active = data.active;
        if (active && (active.state === "Active" || active.state === "active")) {
          if (!currentInstance) currentInstance = generateAvInstanceId();
          await postJson("/api/av/join", {
            channel,
            session_id: active.id,
            instance: currentInstance,
          });
          return {
            sessionId: active.id,
            instance: currentInstance,
            joinedExisting: true,
            session: active,
          };
        }
      }
    } catch (e) {
      console.warn("[av] discover sessions failed:", e);
    }

    currentInstance = generateAvInstanceId();
    await postJson("/api/av/start", {
      channel,
      instance: currentInstance,
    });

    // Converge on the session we just created (av-state may lag).
    let sessionId = null;
    let session = null;
    for (let i = 0; i < 16; i++) {
      await new Promise((r) => setTimeout(r, 500));
      try {
        const r = await fetch(
          `/api/v1/channels/${encodeURIComponent(channel)}/sessions`,
          { credentials: "same-origin" }
        );
        if (!r.ok) continue;
        const d = await r.json();
        if (d.active && (d.active.state === "Active" || d.active.state === "active")) {
          sessionId = d.active.id;
          session = d.active;
          break;
        }
      } catch {
        /* keep polling */
      }
    }

    return {
      sessionId,
      instance: currentInstance,
      joinedExisting: false,
      session,
    };
  } finally {
    startInFlight.delete(key);
  }
}

export async function joinAvSession(channel, sessionId) {
  if (!sessionId) return;
  if (!currentInstance) currentInstance = generateAvInstanceId();
  await postJson("/api/av/join", {
    channel,
    session_id: sessionId,
    instance: currentInstance,
  });
  return { sessionId, instance: currentInstance };
}

export async function leaveAvSession(channel, sessionId) {
  if (!sessionId) return;
  try {
    await postJson("/api/av/leave", {
      channel,
      session_id: sessionId,
      instance: currentInstance || undefined,
    });
  } finally {
    currentInstance = null;
  }
}

export async function endAvSession(channel, sessionId) {
  if (!sessionId) return;
  await postJson("/api/av/end", {
    channel,
    session_id: sessionId,
  });
  currentInstance = null;
}

export async function fetchSessionDetail(sessionId) {
  const resp = await fetch(
    `/api/v1/sessions/${encodeURIComponent(sessionId)}`,
    { credentials: "same-origin" }
  );
  if (!resp.ok) return null;
  return resp.json();
}

export async function fetchAvToken(sessionId) {
  const resp = await fetch(
    `/api/v1/av/sessions/${encodeURIComponent(sessionId)}/token`,
    { credentials: "same-origin" }
  );
  if (!resp.ok) return null;
  const data = await resp.json().catch(() => ({}));
  return data.token || null;
}
