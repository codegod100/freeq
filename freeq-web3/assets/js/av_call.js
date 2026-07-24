/**
 * Phoenix LiveView hook for AV calls.
 *
 * LiveView owns call signaling (start/join/leave TAGMSG). This hook owns
 * the MoQ media plane: load components, publish local A/V, subscribe to
 * remote participants as video/audio tiles, mute, camera, roster polling.
 */

import { loadMoqComponents } from "./moq_loader";
import { broadcastName, computeParticipantSlots } from "./av_mesh";
import { fetchSessionDetail, fetchAvToken, leaveAvSession } from "./av_session";

const AvCall = {
  mounted() {
    this.active = true;
    this.left = false;
    this.mediaStarted = false;
    this.sessionId = blankToNull(this.el.dataset.sessionId);
    this.channel = this.el.dataset.channel || "";
    this.nick = this.el.dataset.nick || "";
    this.instance = this.el.dataset.instance || "";
    this.muted = this.el.dataset.muted === "true";
    this.cameraOn = this.el.dataset.camera === "true";
    this.avOrigin = (this.el.dataset.avOrigin || "").replace(/\/$/, "");
    this.moqToken = null;
    this.pubEl = null;
    this.watchEls = new Map();
    this.pollTimer = null;
    this.previewTimer = null;
    this.statusTimer = null;

    this.localVideo = this.el.querySelector("#av-local-video");
    this.localTile = this.el.querySelector("#av-local-tile");
    this.remoteRoot = this.el.querySelector("#av-remote-tiles");
    this.videoGrid = this.el.querySelector("#av-video-grid");

    this.onTileClick = (e) => this.handleTileClick(e);
    this.onTileKeydown = (e) => {
      if (e.key !== "Enter" && e.key !== " ") return;
      const tile = e.target?.closest?.(".av-tile");
      if (!tile || !this.el.contains(tile)) return;
      e.preventDefault();
      this.toggleTileEnlarged(tile);
    };
    this.videoGrid?.addEventListener("click", this.onTileClick);
    this.videoGrid?.addEventListener("keydown", this.onTileKeydown);

    this.setupEvents();
    this.syncLocalChrome();

    // Session id may already be present (join existing call) or arrive later
    // via data-session-id / av_state. Always try ensureMedia.
    this.ensureMedia("mounted");
  },

  updated() {
    const prevSession = this.sessionId;
    this.channel = this.el.dataset.channel || this.channel;
    this.nick = this.el.dataset.nick || this.nick;
    this.instance = this.el.dataset.instance || this.instance;
    this.muted = this.el.dataset.muted === "true";
    this.avOrigin = (this.el.dataset.avOrigin || this.avOrigin || "").replace(
      /\/$/,
      "",
    );
    this.sessionId = blankToNull(this.el.dataset.sessionId) || this.sessionId;

    const camera = this.el.dataset.camera === "true";
    if (camera !== this.cameraOn) {
      this.cameraOn = camera;
      this.onCameraChanged();
    }
    this.applyMute();
    this.syncLocalChrome();

    // Critical: LiveView often lands av_session_id via DOM patch *before*
    // (or instead of) push_event ordering. updated() must start media.
    if (this.sessionId && this.sessionId !== prevSession) {
      this.ensureMedia("updated-session");
    } else if (this.sessionId && !this.pubEl) {
      this.ensureMedia("updated-retry");
    }
  },

  destroyed() {
    this.active = false;
    this.videoGrid?.removeEventListener("click", this.onTileClick);
    this.videoGrid?.removeEventListener("keydown", this.onTileKeydown);
    this.teardown();
    if (!this.left && this.channel && this.sessionId) {
      leaveAvSession(this.channel, this.sessionId, this.instance);
    }
  },

  /** Click a tile to enlarge; click again (or another tile) to collapse. */
  handleTileClick(e) {
    const tile = e.target?.closest?.(".av-tile");
    if (!tile || !this.el.contains(tile)) return;
    // Ignore accidental clicks on form controls if any land inside a tile.
    if (e.target?.closest?.("button, a, input, select, textarea")) return;
    this.toggleTileEnlarged(tile);
  },

  toggleTileEnlarged(tile) {
    if (!tile) return;
    const was = tile.classList.contains("is-enlarged");
    this.el
      .querySelectorAll(".av-tile.is-enlarged")
      .forEach((t) => t.classList.remove("is-enlarged"));
    if (!was) {
      tile.classList.add("is-enlarged");
      tile.scrollIntoView?.({ block: "nearest", behavior: "smooth" });
    }
  },

  setupEvents() {
    this.handleEvent("av_token", ({ session_id, token }) => {
      if (!this.active || !session_id || !token) return;
      this.moqToken = token;
      this.sessionId = session_id;
      this.applyMoqUrl();
      this.ensureMedia("av_token");
    });

    this.handleEvent("av_state", ({ session_id, state }) => {
      if (!this.active) return;
      const s = String(state || "").toLowerCase();
      if (session_id) this.sessionId = session_id;
      if (s === "started" || s === "joined") {
        this.ensureMedia("av_state");
        this.pollRoster();
      }
    });

    this.handleEvent("av_muted", ({ muted }) => {
      this.muted = !!muted;
      this.applyMute();
      this.syncLocalChrome();
    });

    this.handleEvent("av_camera", ({ camera }) => {
      const next = !!camera;
      if (next === this.cameraOn) return;
      this.cameraOn = next;
      this.onCameraChanged();
    });

    this.handleEvent("av_ended", () => {
      this.active = false;
      this.left = true;
      this.teardown();
    });
  },

  /** Start publish + roster once we have sessionId + nick. Idempotent. */
  ensureMedia(reason) {
    if (!this.active) return;
    if (!this.sessionId || !this.nick) {
      console.log("[av] ensureMedia wait", reason, {
        sessionId: this.sessionId,
        nick: this.nick,
      });
      return;
    }
    if (!this.pollTimer) this.beginRosterPoll();
    this.fetchTokenSoon(this.sessionId);
    if (!this.pubEl) this.startMedia(reason);
  },

  moqUrl() {
    // Prefer freeq-server origin (data-av-origin). Phoenix does not proxy MoQ.
    const origin = (window.FREEQ_AV_ORIGIN || this.avOrigin || "").replace(
      /\/$/,
      "",
    );
    let base;
    if (origin) {
      try {
        const u = new URL(origin);
        const wsProto = u.protocol === "https:" ? "wss:" : "ws:";
        const port =
          u.port &&
          !(
            (u.protocol === "https:" && u.port === "443") ||
            (u.protocol === "http:" && u.port === "80")
          )
            ? `:${u.port}`
            : u.port
              ? `:${u.port}`
              : "";
        // URL.port is empty when default; host includes non-default port.
        base = `${wsProto}//${u.host}/av/moq`;
      } catch {
        base = `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/av/moq`;
      }
    } else {
      base = `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/av/moq`;
    }
    return this.moqToken
      ? `${base}?jwt=${encodeURIComponent(this.moqToken)}`
      : base;
  },

  applyMoqUrl() {
    const url = this.moqUrl();
    if (this.pubEl && this.pubEl.getAttribute("url") !== url) {
      this.stopPublishEl();
      this.buildPublishEl(this.cameraOn);
    }
    for (const el of this.watchEls.values()) {
      if (el.getAttribute("url") !== url) el.setAttribute("url", url);
    }
  },

  async startMedia(reason) {
    if (!this.active || !this.sessionId || !this.nick || this.pubEl) return;

    console.log("[av] startMedia", reason, this.sessionId, this.moqUrl());

    try {
      await loadMoqComponents();
    } catch (e) {
      console.error("[av] MoQ load failed:", e);
      this.setLocalStatus("media load failed");
      return;
    }

    // Permission probe — stop immediately so moq-publish owns capture.
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: true,
        video: this.cameraOn,
      });
      stream.getTracks().forEach((t) => t.stop());
    } catch (e) {
      console.warn("[av] media permission probe:", e);
      if (this.cameraOn) {
        try {
          const audioOnly = await navigator.mediaDevices.getUserMedia({
            audio: true,
          });
          audioOnly.getTracks().forEach((t) => t.stop());
          this.cameraOn = false;
        } catch (e2) {
          console.warn("[av] mic permission denied:", e2);
          this.setLocalStatus("mic denied");
          return;
        }
      } else {
        this.setLocalStatus("mic denied");
        return;
      }
    }

    this.buildPublishEl(this.cameraOn);
    this.beginLocalPreviewPoll();
    this.beginStatusPoll();
    this.mediaStarted = true;
  },

  onCameraChanged() {
    if (this.pubEl) {
      this.stopPublishEl();
      this.buildPublishEl(this.cameraOn);
    }
    this.syncLocalChrome();
    this.updateLocalPreview();
  },

  buildPublishEl(withVideo) {
    const container = this.el.querySelector("#av-publish-container");
    if (!container || !this.sessionId || !this.nick) return;

    container.innerHTML = "";

    const pub = document.createElement("moq-publish");
    container.appendChild(pub);
    this.pubEl = pub;

    const name = broadcastName(this.sessionId, this.nick, this.instance);
    const url = this.moqUrl();
    pub.setAttribute("url", url);
    pub.setAttribute("name", name);
    // invisible BEFORE source: audio-only path doesn't open the camera.
    if (!withVideo) pub.setAttribute("invisible", "");
    if (this.muted) {
      pub.setAttribute("muted", "");
      pub.muted = true;
    }
    pub.setAttribute("source", "camera");
    console.log(
      "[av] publishing:",
      name,
      withVideo ? "(video)" : "(audio-only)",
      "url=",
      url.replace(/jwt=[^&]+/, "jwt=…"),
    );
    this.syncLocalChrome();
    this.setLocalStatus(withVideo ? "camera" : "audio live");
    setTimeout(() => this.updateLocalPreview(), 400);
    setTimeout(() => this.updateLocalPreview(), 1200);
  },

  stopPublishEl() {
    const pub = this.pubEl;
    if (!pub) return;
    pub.muted = true;
    pub.paused = true;
    pub.setAttribute("muted", "");
    pub.removeAttribute("source");
    pub.setAttribute("url", "");
    pub.remove();
    this.pubEl = null;
    if (this.localVideo) {
      this.localVideo.srcObject = null;
      this.localVideo.hidden = true;
    }
  },

  applyMute() {
    const pub = this.pubEl;
    if (!pub) return;
    if (this.muted) {
      pub.setAttribute("muted", "");
    } else {
      pub.removeAttribute("muted");
    }
    pub.muted = this.muted;
  },

  beginLocalPreviewPoll() {
    if (this.previewTimer) clearInterval(this.previewTimer);
    this.previewTimer = setInterval(() => {
      if (!this.active) return;
      this.updateLocalPreview();
    }, 1000);
  },

  beginStatusPoll() {
    if (this.statusTimer) clearInterval(this.statusTimer);
    this.statusTimer = setInterval(() => {
      if (!this.active) return;
      this.refreshRemoteStatuses();
    }, 800);
  },

  updateLocalPreview() {
    if (!this.localVideo || !this.localTile) return;

    if (!this.cameraOn) {
      this.localVideo.srcObject = null;
      this.localVideo.hidden = true;
      this.localTile.classList.remove("has-video");
      this.localTile.classList.add("has-audio");
      return;
    }

    const track = this.pubEl?.video?.peek?.()?.source?.peek?.();
    if (track && track.readyState === "live") {
      const current = this.localVideo.srcObject;
      const existing = current?.getVideoTracks?.()?.[0];
      if (existing !== track) {
        this.localVideo.srcObject = new MediaStream([track]);
      }
      this.localVideo.hidden = false;
      this.localTile.classList.add("has-video", "has-audio");
      this.localVideo.play?.().catch(() => {});
    }
  },

  setLocalStatus(text) {
    if (!this.localTile) return;
    const label = this.localTile.querySelector(".av-tile-label");
    if (!label) return;
    const bits = ["You"];
    if (this.muted) bits.push("muted");
    else if (text) bits.push(text);
    else if (!this.cameraOn) bits.push("audio");
    label.textContent = bits.join(" · ");
  },

  syncLocalChrome() {
    if (!this.localTile) return;
    this.localTile.classList.toggle("is-muted", !!this.muted);
    this.localTile.classList.toggle("is-camera-on", !!this.cameraOn);
    this.localTile.classList.toggle("has-audio", !!this.pubEl);
    this.setLocalStatus(
      this.cameraOn ? "camera" : this.pubEl ? "audio live" : "connecting…",
    );
  },

  beginRosterPoll() {
    if (this.pollTimer) clearInterval(this.pollTimer);
    this.pollRoster();
    this.pollTimer = setInterval(() => this.pollRoster(), 1200);
  },

  async pollRoster() {
    if (!this.active || !this.sessionId) return;
    try {
      const data = await fetchSessionDetail(this.sessionId);
      if (!data?.participants) return;

      const slots = computeParticipantSlots(
        data.participants,
        { nick: this.nick, instance: this.instance, did: null },
        this.sessionId,
      );
      this.syncRemoteTiles(slots);

      this.pushEvent?.("av_roster", {
        count: (data.participants || []).length,
      });
    } catch (e) {
      console.warn("[av] roster poll failed:", e);
    }
  },

  syncRemoteTiles(slots) {
    const root = this.remoteRoot || this.el.querySelector("#av-remote-tiles");
    if (!root) return;
    const nextKeys = new Set(slots.map((s) => s.broadcastKey));

    for (const [key, el] of this.watchEls) {
      if (!nextKeys.has(key)) {
        this.destroyWatch(el);
        this.watchEls.delete(key);
        root
          .querySelector(`[data-broadcast-key="${CSS.escape(key)}"]`)
          ?.remove();
      }
    }

    for (const slot of slots) {
      if (this.watchEls.has(slot.broadcastKey)) {
        // Keep url/name fresh if token arrived late.
        const el = this.watchEls.get(slot.broadcastKey);
        const url = this.moqUrl();
        if (el.getAttribute("url") !== url) el.setAttribute("url", url);
        continue;
      }

      const tile = document.createElement("div");
      tile.className = "av-tile av-tile-remote has-audio";
      tile.dataset.broadcastKey = slot.broadcastKey;
      tile.title = "Click to enlarge";
      tile.setAttribute("role", "button");
      tile.setAttribute("tabindex", "0");
      tile.innerHTML = `
        <div class="av-tile-avatar">${escapeHtml(initials(slot.nick))}</div>
        <div class="av-tile-watch"></div>
        <div class="av-tile-pulse" aria-hidden="true"></div>
        <div class="av-tile-audio-badge" title="Audio">🔊</div>
        <span class="av-tile-label">${escapeHtml(slot.nick)} · connecting…</span>
      `;
      root.appendChild(tile);

      const mount = tile.querySelector(".av-tile-watch");
      const watchEl = document.createElement("moq-watch");
      const canvas = document.createElement("canvas");
      canvas.className = "av-tile-canvas";
      // Explicit size helps IntersectionObserver / first paint in moq-watch.
      canvas.width = 320;
      canvas.height = 240;
      watchEl.appendChild(canvas);
      watchEl.style.cssText =
        "position:absolute;inset:0;width:100%;height:100%;display:block";
      watchEl.setAttribute("jitter", "80");
      watchEl.setAttribute("reload", "");
      watchEl.setAttribute("url", this.moqUrl());
      watchEl.setAttribute("name", slot.broadcastName);
      mount.appendChild(watchEl);
      this.watchEls.set(slot.broadcastKey, watchEl);

      console.log(
        "[av] subscribing to:",
        slot.broadcastName,
        this.moqUrl().replace(/jwt=[^&]+/, "jwt=…"),
      );
    }
  },

  refreshRemoteStatuses() {
    for (const [key, watchEl] of this.watchEls) {
      const tile = this.remoteRoot?.querySelector(
        `[data-broadcast-key="${CSS.escape(key)}"]`,
      );
      if (!tile) continue;

      const status =
        watchEl.broadcast?.status?.peek?.() ||
        watchEl.broadcast?.status?.value ||
        null;

      const label = tile.querySelector(".av-tile-label");
      const nick =
        label?.textContent?.split(" · ")[0] || tile.dataset.broadcastKey || "?";

      if (status === "live") {
        tile.classList.add("is-live", "has-audio");
        // If canvas is painting, promote to has-video.
        const canvas = watchEl.querySelector("canvas");
        if (canvas && canvas.width > 2 && canvas.height > 2) {
          try {
            const ctx = canvas.getContext("2d", { willReadFrequently: true });
            if (ctx) {
              const sample = ctx.getImageData(
                Math.floor(canvas.width / 2),
                Math.floor(canvas.height / 2),
                1,
                1,
              ).data;
              if (sample[0] + sample[1] + sample[2] > 12) {
                tile.classList.add("has-video");
              }
            }
          } catch {
            /* ignore */
          }
        }
        if (label) {
          label.textContent = tile.classList.contains("has-video")
            ? nick
            : `${nick} · audio`;
        }
      } else if (status === "loading" || status === "offline") {
        tile.classList.remove("is-live");
        if (label) label.textContent = `${nick} · ${status || "…"}`;
      }
    }
  },

  destroyWatch(el) {
    if (!el) return;
    el.paused = true;
    el.setAttribute("url", "");
    el.setAttribute("name", "");
    el.remove();
  },

  async fetchTokenSoon(sessionId) {
    // Prefer IRC TAGMSG (+freeq.at/av-token → push_event av_token). REST is
    // a fallback that needs SASL API-BEARER + DID participant.
    if (this.moqToken) return;
    // Give TAGMSG a head start before hammering REST (avoids 401 spam).
    await new Promise((r) => setTimeout(r, 600));
    if (this.moqToken || !this.active || this.sessionId !== sessionId) return;

    for (let i = 0; i < 6; i++) {
      if (this.moqToken || !this.active || this.sessionId !== sessionId) return;
      try {
        const tok = await fetchAvToken(sessionId);
        if (tok) {
          this.moqToken = tok;
          console.log("[av] token via REST");
          this.applyMoqUrl();
          return;
        }
      } catch {
        /* retry */
      }
      await new Promise((r) => setTimeout(r, 500 + i * 250));
    }
    if (!this.moqToken) {
      console.warn(
        "[av] no MoQ token yet (REST 401/403 is normal without SASL — waiting for TAGMSG)",
      );
    }
  },

  teardown() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
    if (this.previewTimer) {
      clearInterval(this.previewTimer);
      this.previewTimer = null;
    }
    if (this.statusTimer) {
      clearInterval(this.statusTimer);
      this.statusTimer = null;
    }
    this.stopPublishEl();
    for (const el of this.watchEls.values()) this.destroyWatch(el);
    this.watchEls.clear();
    if (this.remoteRoot) this.remoteRoot.innerHTML = "";
    this.mediaStarted = false;
  },
};

function blankToNull(s) {
  if (s == null) return null;
  const t = String(s).trim();
  return t === "" ? null : t;
}

function initials(nick) {
  const s = String(nick || "?").trim();
  if (!s) return "?";
  return s.slice(0, 2).toUpperCase();
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export default AvCall;
