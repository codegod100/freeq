/**
 * Phoenix LiveView hook for AV calls.
 *
 * The LiveView owns the call button and signals start/join/leave via IRC
 * TAGMSG. This hook manages the MoQ media plane: load components, publish
 * local audio, subscribe to remote participants, mute, and roster polling.
 */

import { loadMoqComponents } from "./moq_loader";
import { broadcastName, computeParticipantSlots } from "./av_mesh";
import { fetchSessionDetail, fetchAvToken, leaveAvSession } from "./av_session";

const AvCall = {
  mounted() {
    this.active = true;
    this.left = false;
    this.sessionId = this.el.dataset.sessionId || null;
    this.channel = this.el.dataset.channel || "";
    this.nick = this.el.dataset.nick || "";
    this.instance = this.el.dataset.instance || "";
    this.muted = this.el.dataset.muted === "true";
    this.moqToken = null;
    this.pubEl = null;
    this.watchEls = new Map();
    this.pollTimer = null;
    this.tokenTimer = null;

    this.setupEvents();

    if (this.sessionId) {
      this.beginRosterPoll();
      this.fetchTokenSoon(this.sessionId);
      this.startMedia();
    }
  },

  updated() {
    this.channel = this.el.dataset.channel || this.channel;
    this.nick = this.el.dataset.nick || this.nick;
    this.instance = this.el.dataset.instance || this.instance;
    this.muted = this.el.dataset.muted === "true";
    this.sessionId = this.el.dataset.sessionId || this.sessionId;
  },

  destroyed() {
    this.active = false;
    this.teardown();
    if (!this.left && this.channel && this.sessionId) {
      leaveAvSession(this.channel, this.sessionId, this.instance);
    }
  },

  setupEvents() {
    this.handleEvent("av_token", ({ session_id, token }) => {
      if (!this.active || !session_id || !token) return;
      this.moqToken = token;
      this.sessionId = session_id;
      this.applyMoqUrl();
    });

    this.handleEvent("av_state", ({ session_id, state, participants }) => {
      if (!this.active) return;
      const s = String(state || "").toLowerCase();
      if (s === "started" || s === "joined") {
        if (session_id && !this.sessionId) {
          this.sessionId = session_id;
          this.beginRosterPoll();
          this.fetchTokenSoon(session_id);
          this.startMedia();
        }
        this.pollRoster();
      }
    });

    this.handleEvent("av_muted", ({ muted }) => {
      this.muted = muted;
      this.applyMute();
    });

    this.handleEvent("av_ended", () => {
      this.active = false;
      this.left = true;
      this.teardown();
    });
  },

  moqUrl() {
    const base = `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/av/moq`;
    return this.moqToken
      ? `${base}?jwt=${encodeURIComponent(this.moqToken)}`
      : base;
  },

  applyMoqUrl() {
    if (this.pubEl && this.pubEl.getAttribute("url") !== this.moqUrl()) {
      this.stopPublishEl();
      this.buildPublishEl();
    }
    for (const [key, el] of this.watchEls) {
      el.setAttribute("url", this.moqUrl());
    }
  },

  async startMedia() {
    if (!this.active || !this.sessionId || !this.nick || this.pubEl) return;

    try {
      await loadMoqComponents();
    } catch (e) {
      console.error("[av] MoQ load failed:", e);
      return;
    }

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      stream.getTracks().forEach((t) => t.stop());
    } catch (e) {
      console.warn("[av] mic permission probe:", e);
    }

    this.buildPublishEl();
  },

  buildPublishEl() {
    const container = this.el.querySelector("#av-publish-container");
    if (!container || !this.sessionId || !this.nick || this.pubEl) return;

    const pub = document.createElement("moq-publish");
    container.appendChild(pub);
    this.pubEl = pub;

    const name = broadcastName(this.sessionId, this.nick, this.instance);
    pub.setAttribute("url", this.moqUrl());
    pub.setAttribute("name", name);
    pub.setAttribute("invisible", "");
    pub.setAttribute("source", "camera");
    this.applyMute();
    console.log("[av] publishing:", name);
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
        this.sessionId
      );
      this.syncRemoteTiles(slots);
    } catch (e) {
      console.warn("[av] roster poll failed:", e);
    }
  },

  syncRemoteTiles(slots) {
    const root = this.el.querySelector("#av-remote-tiles");
    if (!root) return;
    const nextKeys = new Set(slots.map((s) => s.broadcastKey));

    for (const [key, el] of this.watchEls) {
      if (!nextKeys.has(key)) {
        this.destroyWatch(el);
        this.watchEls.delete(key);
        root.querySelector(`[data-broadcast-key="${CSS.escape(key)}"]`)?.remove();
      }
    }

    for (const slot of slots) {
      if (this.watchEls.has(slot.broadcastKey)) continue;
      const tile = document.createElement("div");
      tile.className = "av-remote-tile";
      tile.dataset.broadcastKey = slot.broadcastKey;
      tile.innerHTML = `
        <div class="av-tile-avatar">${escapeHtml(slot.nick.slice(0, 2).toUpperCase())}</div>
        <div class="av-tile-watch"></div>
        <span class="av-tile-label">${escapeHtml(slot.nick)}</span>
      `;
      root.appendChild(tile);

      const mount = tile.querySelector(".av-tile-watch");
      const watchEl = document.createElement("moq-watch");
      const canvas = document.createElement("canvas");
      canvas.className = "av-tile-canvas";
      watchEl.appendChild(canvas);
      watchEl.style.cssText = "position:absolute;inset:0;width:100%;height:100%";
      watchEl.setAttribute("jitter", "80");
      watchEl.setAttribute("reload", "");
      watchEl.setAttribute("url", this.moqUrl());
      watchEl.setAttribute("name", slot.broadcastName);
      mount.appendChild(watchEl);
      this.watchEls.set(slot.broadcastKey, watchEl);
      console.log("[av] subscribing to:", slot.broadcastName);
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
    for (let i = 0; i < 6; i++) {
      if (this.moqToken || !this.active || this.sessionId !== sessionId) return;
      await new Promise((r) => setTimeout(r, 400 + i * 200));
      try {
        const tok = await fetchAvToken(sessionId);
        if (tok) {
          this.moqToken = tok;
          this.applyMoqUrl();
          return;
        }
      } catch {
        /* retry */
      }
    }
  },

  teardown() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
    if (this.tokenTimer) {
      clearTimeout(this.tokenTimer);
      this.tokenTimer = null;
    }
    this.stopPublishEl();
    for (const el of this.watchEls.values()) this.destroyWatch(el);
    this.watchEls.clear();
    const root = this.el?.querySelector("#av-remote-tiles");
    if (root) root.innerHTML = "";
  },
};

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export default AvCall;
