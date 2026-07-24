/**
 * Client-side AV session REST helpers.
 */

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

export async function leaveAvSession(channel, sessionId, instance) {
  if (!sessionId) return;
  try {
    await postJson("/api/av/leave", {
      channel,
      session_id: sessionId,
      instance: instance || undefined,
    });
  } catch (e) {
    console.warn("[av] leave failed:", e);
  }
}
