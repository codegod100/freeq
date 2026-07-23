import { Controller } from "@hotwired/stimulus";
import { loadMoqComponents } from "../av/moq_loader";
import { broadcastName, computeParticipantSlots } from "../av/mesh";
import {
  startOrJoinAvSession,
  leaveAvSession,
  endAvSession,
  getAvInstanceId,
  fetchSessionDetail,
  fetchAvToken,
} from "../av/session";

/**
 * Voice call UI for freeq-web2.
 *
 * Signaling: IRC TAGMSG via Rails BFF (/api/av/*).
 * Media: moq-publish / moq-watch against the freeq-server SFU (MoQ).
 *
 * Targets (optional — graceful if missing):
 *   panel, status, participantCount, videoGrid, remoteTiles,
 *   localVideo, publishContainer, voiceBtn, connectedBar,
 *   connectedLabel, micBtn, camBtn, leaveBtn, endBtn, notice
 */
export default class CallController extends Controller {
  static targets = [
    "panel",
    "status",
    "participantCount",
    "videoGrid",
    "remoteTiles",
    "localVideo",
    "publishContainer",
    "voiceBtn",
    "connectedBar",
    "connectedLabel",
    "micBtn",
    "camBtn",
    "leaveBtn",
    "endBtn",
    "notice",
  ];

  static values = {
    channel: String,
    nick: String,
    did: String,
    avOrigin: String,
    authenticated: Boolean,
  };

  connect() {
    this.active = false;
    this.sessionId = null;
    this.muted = false;
    this.cameraOn = false;
    this.pubEl = null;
    this.watchEls = new Map(); // broadcastKey → element
    this.pollTimer = null;
    this.moqToken = null;
    this.participantNicks = [];
    this._startInFlight = false;

    this._onAvState = (ev) => this.handleAvState(ev.detail || {});
    this._onAvToken = (ev) => this.handleAvToken(ev.detail || {});
    this.element.addEventListener("freeq:av_state", this._onAvState);
    this.element.addEventListener("freeq:av_token", this._onAvToken);

    // Discover existing call in this channel (sidebar indicator).
    this.pollChannelSession();
    this._discoverTimer = setInterval(() => this.pollChannelSession(), 5000);

    this.syncChrome();
  }

  disconnect() {
    this.element.removeEventListener("freeq:av_state", this._onAvState);
    this.element.removeEventListener("freeq:av_token", this._onAvToken);
    if (this._discoverTimer) clearInterval(this._discoverTimer);
    if (this.active) {
      // Best-effort leave on navigation away.
      this.teardownMedia();
      if (this.sessionId && this.channelValue) {
        leaveAvSession(this.channelValue, this.sessionId).catch(() => {});
      }
    }
  }

  // ── UI actions ──────────────────────────────────────────────

  async toggleCall(event) {
    event?.preventDefault?.();
    if (this.active) {
      await this.leave();
    } else {
      await this.start();
    }
  }

  async start() {
    if (this.active || this._startInFlight) return;
    if (!this.authenticatedValue || !this.didValue?.startsWith("did:")) {
      this.showNotice("Sign in with AT Protocol to start a voice call.");
      return;
    }
    if (!this.channelValue?.startsWith("#")) {
      this.showNotice("Voice calls are available in channels.");
      return;
    }

    this._startInFlight = true;
    this.setStatus("Starting voice…");
    try {
      const result = await startOrJoinAvSession(this.channelValue);
      if (!result) return;

      this.sessionId = result.sessionId;
      this.active = true;
      this.muted = false;
      this.cameraOn = false;
      this.syncChrome();

      if (result.joinedExisting) {
        this.setStatus("Joining voice…");
      } else {
        this.setStatus(result.sessionId ? "Connecting audio…" : "Waiting for session…");
      }

      // Token may arrive via TAGMSG; also try REST as fallback.
      if (this.sessionId) {
        this.fetchTokenSoon(this.sessionId);
      }

      await this.startMedia();
      this.beginRosterPoll();
    } catch (e) {
      console.error("[call] start failed:", e);
      this.showNotice(e.message || "Could not start voice call");
      this.active = false;
      this.sessionId = null;
      this.syncChrome();
    } finally {
      this._startInFlight = false;
    }
  }

  async leave() {
    const channel = this.channelValue;
    const sid = this.sessionId;
    this.teardownMedia();
    this.active = false;
    this.sessionId = null;
    this.moqToken = null;
    this.participantNicks = [];
    this.syncChrome();
    this.setStatus("");
    if (channel && sid) {
      try {
        await leaveAvSession(channel, sid);
      } catch (e) {
        console.warn("[call] leave failed:", e);
      }
    }
  }

  async endForAll() {
    const channel = this.channelValue;
    const sid = this.sessionId;
    await this.leave();
    if (channel && sid) {
      try {
        await endAvSession(channel, sid);
      } catch (e) {
        console.warn("[call] end failed:", e);
      }
    }
  }

  toggleMute(event) {
    event?.preventDefault?.();
    if (!this.active) return;
    this.muted = !this.muted;
    this.applyMute();
    this.syncChrome();
  }

  async toggleCamera(event) {
    event?.preventDefault?.();
    if (!this.active || !this.sessionId) return;
    this.cameraOn = !this.cameraOn;
    // Recreate publisher so catalog re-announces with/without video.
    this.stopPublishEl();
    this.buildPublishEl(this.cameraOn);
    this.syncChrome();
    this.updateLocalPreview();
  }

  // ── Events from broadcaster ─────────────────────────────────

  handleAvState(detail) {
    const ch = String(detail.channel || "");
    if (ch && this.channelValue && ch.toLowerCase() !== this.channelValue.toLowerCase()) {
      // Still update discovery badge if another channel — ignore for panel.
      return;
    }

    const state = String(detail.state || "").toLowerCase();
    const sid = detail.sessionId;

    if (state === "started" || state === "joined") {
      if (this.active && !this.sessionId && sid) {
        this.sessionId = sid;
        this.fetchTokenSoon(sid);
        this.beginRosterPoll();
        this.startMedia().catch((e) => console.error("[call] media:", e));
      }
      if (this.active && sid) this.sessionId = sid;
      this.pollChannelSession();
      if (this.active) this.pollRoster();
    }

    if (state === "left") {
      if (this.active) this.pollRoster();
      this.pollChannelSession();
    }

    if (state === "ended") {
      if (this.active && this.sessionId === sid) {
        this.teardownMedia();
        this.active = false;
        this.sessionId = null;
        this.moqToken = null;
        this.syncChrome();
        this.setStatus("Call ended");
        setTimeout(() => this.setStatus(""), 2500);
      }
      this.pollChannelSession();
    }
  }

  handleAvToken(detail) {
    if (!detail.sessionId || !detail.token) return;
    if (this.sessionId && detail.sessionId !== this.sessionId) return;
    this.moqToken = detail.token;
    // Redial publisher if already live with a tokenless URL.
    if (this.pubEl && this.pubEl.getAttribute("url") !== this.moqUrl()) {
      this.stopPublishEl();
      this.buildPublishEl(this.cameraOn);
    }
  }

  // ── Media ───────────────────────────────────────────────────

  moqUrl() {
    const origin = (this.avOriginValue || "").replace(/\/$/, "");
    let base;
    if (origin) {
      try {
        const u = new URL(origin);
        const wsProto = u.protocol === "https:" ? "wss:" : "ws:";
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
  }

  async startMedia() {
    if (!this.active || !this.sessionId || !this.nickValue) return;

    try {
      await loadMoqComponents();
    } catch (e) {
      console.error("[call] MoQ load failed:", e);
      this.showNotice("Failed to load audio components");
      await this.leave();
      return;
    }

    // Permission probe — stop immediately so moq-publish owns capture.
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      stream.getTracks().forEach((t) => t.stop());
    } catch (e) {
      const name = e?.name || "";
      const reason =
        name === "NotAllowedError"
          ? "microphone permission denied"
          : name === "NotFoundError"
            ? "no microphone found"
            : e?.message || "unknown error";
      this.showNotice(`Microphone error: ${reason}`);
      await this.leave();
      return;
    }

    this.buildPublishEl(this.cameraOn);
    this.setStatus("Voice connected");
  }

  buildPublishEl(withVideo) {
    const container = this.hasPublishContainerTarget
      ? this.publishContainerTarget
      : null;
    if (!container || !this.sessionId || !this.nickValue) return null;

    const pub = document.createElement("moq-publish");
    container.appendChild(pub);
    this.pubEl = pub;

    const instance = getAvInstanceId();
    const name = broadcastName(this.sessionId, this.nickValue, instance);
    pub.setAttribute("url", this.moqUrl());
    pub.setAttribute("name", name);
    if (!withVideo) pub.setAttribute("invisible", "");
    if (this.muted) {
      pub.setAttribute("muted", "");
      pub.muted = true;
    }
    pub.setAttribute("source", "camera");
    console.log("[call] Publishing:", name, withVideo ? "(video)" : "(audio-only)");
    return pub;
  }

  stopPublishEl() {
    const pub = this.pubEl;
    if (!pub) return;
    pub.muted = true;
    pub.paused = true;
    pub.setAttribute("muted", "");
    // removeAttribute('source') — never set to '' (throws inside moq-publish).
    pub.removeAttribute("source");
    pub.setAttribute("url", "");
    pub.remove();
    this.pubEl = null;
    if (this.hasLocalVideoTarget) {
      this.localVideoTarget.srcObject = null;
    }
  }

  applyMute() {
    const pub = this.pubEl;
    if (!pub) return;
    if (this.muted) {
      pub.setAttribute("muted", "");
    } else {
      pub.removeAttribute("muted");
    }
    pub.muted = this.muted;
  }

  updateLocalPreview() {
    if (!this.hasLocalVideoTarget) return;
    const video = this.localVideoTarget;
    if (!this.cameraOn) {
      video.srcObject = null;
      video.hidden = true;
      return;
    }
    video.hidden = false;
    // Best-effort: moq may expose video track later; optional local preview.
    const track = this.pubEl?.video?.peek?.()?.source?.peek?.();
    if (track) {
      video.srcObject = new MediaStream([track]);
    }
  }

  beginRosterPoll() {
    if (this.pollTimer) clearInterval(this.pollTimer);
    this.pollRoster();
    this.pollTimer = setInterval(() => this.pollRoster(), 1200);
  }

  async pollRoster() {
    if (!this.active || !this.sessionId) return;
    try {
      const data = await fetchSessionDetail(this.sessionId);
      if (!data?.participants) return;

      const slots = computeParticipantSlots(
        data.participants,
        {
          nick: this.nickValue,
          instance: getAvInstanceId(),
          did: this.didValue || null,
        },
        this.sessionId
      );

      this.participantNicks = (data.participants || []).map((p) => p.nick);
      this.syncParticipantCount(data.participants.length);
      this.syncRemoteTiles(slots);
      this.syncChrome();
    } catch (e) {
      console.warn("[call] roster poll failed:", e);
    }
  }

  syncRemoteTiles(slots) {
    if (!this.hasRemoteTilesTarget) return;
    const root = this.remoteTilesTarget;
    const nextKeys = new Set(slots.map((s) => s.broadcastKey));

    // Remove stale watchers
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
      tile.className = "call-tile";
      tile.dataset.broadcastKey = slot.broadcastKey;
      tile.innerHTML = `
        <div class="call-tile-avatar">${escapeHtml(slot.nick.slice(0, 2).toUpperCase())}</div>
        <div class="call-tile-watch"></div>
        <span class="call-tile-label">${escapeHtml(slot.nick)}</span>
      `;
      root.appendChild(tile);

      const mount = tile.querySelector(".call-tile-watch");
      const watchEl = document.createElement("moq-watch");
      const canvas = document.createElement("canvas");
      canvas.className = "call-tile-canvas";
      watchEl.appendChild(canvas);
      watchEl.style.cssText = "position:absolute;inset:0;width:100%;height:100%";
      watchEl.setAttribute("jitter", "80");
      watchEl.setAttribute("reload", "");
      watchEl.setAttribute("url", this.moqUrl());
      watchEl.setAttribute("name", slot.broadcastName);
      mount.appendChild(watchEl);
      this.watchEls.set(slot.broadcastKey, watchEl);
      console.log("[call] Subscribing to:", slot.broadcastName);
    }
  }

  destroyWatch(watchEl) {
    if (!watchEl) return;
    watchEl.paused = true;
    watchEl.setAttribute("url", "");
    watchEl.setAttribute("name", "");
    watchEl.remove();
  }

  teardownMedia() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
    this.stopPublishEl();
    for (const el of this.watchEls.values()) this.destroyWatch(el);
    this.watchEls.clear();
    if (this.hasRemoteTilesTarget) this.remoteTilesTarget.innerHTML = "";
  }

  async fetchTokenSoon(sessionId) {
    // TAGMSG usually arrives first; REST is a fallback after join settles.
    for (let i = 0; i < 6; i++) {
      if (this.moqToken && this.sessionId === sessionId) return;
      await new Promise((r) => setTimeout(r, 400 + i * 200));
      if (!this.active || this.sessionId !== sessionId) return;
      if (this.moqToken) return;
      try {
        const tok = await fetchAvToken(sessionId);
        if (tok) {
          this.moqToken = tok;
          if (this.pubEl && this.pubEl.getAttribute("url") !== this.moqUrl()) {
            this.stopPublishEl();
            this.buildPublishEl(this.cameraOn);
          }
          return;
        }
      } catch {
        /* retry */
      }
    }
  }

  // ── Channel discovery (live call badge) ─────────────────────

  async pollChannelSession() {
    if (!this.channelValue?.startsWith("#")) return;
    try {
      const resp = await fetch(
        `/api/v1/channels/${encodeURIComponent(this.channelValue)}/sessions`,
        { credentials: "same-origin" }
      );
      if (!resp.ok) return;
      const data = await resp.json();
      this.channelHasCall = !!(
        data.active &&
        (data.active.state === "Active" || data.active.state === "active")
      );
      this.channelCallCount = data.active?.participant_count || 0;
      if (!this.active && data.active?.id) {
        this.discoveredSessionId = data.active.id;
      }
      this.syncChrome();
    } catch {
      /* ignore */
    }
  }

  // ── Chrome ──────────────────────────────────────────────────

  syncChrome() {
    if (this.hasPanelTarget) {
      this.panelTarget.hidden = !this.active;
      this.panelTarget.classList.toggle("active", this.active);
      this.panelTarget.classList.toggle("is-muted", this.muted);
      this.panelTarget.classList.toggle("is-camera-on", this.cameraOn);
    }
    if (this.hasConnectedBarTarget) {
      this.connectedBarTarget.hidden = !this.active;
      this.connectedBarTarget.classList.toggle("is-muted", this.muted);
      this.connectedBarTarget.classList.toggle("is-camera-on", this.cameraOn);
    }
    if (this.hasConnectedLabelTarget && this.active) {
      const n = this.participantNicks.length || 1;
      this.connectedLabelTarget.textContent = `${this.channelValue} · ${n}`;
    }
    if (this.hasVoiceBtnTarget) {
      const btn = this.voiceBtnTarget;
      btn.classList.toggle("in-call", this.active);
      btn.classList.toggle("has-call", !this.active && !!this.channelHasCall);
      if (this.active) {
        btn.title = "In voice call — click to leave";
      } else if (this.channelHasCall) {
        btn.title = `Join voice call (${this.channelCallCount || "live"})`;
      } else {
        btn.title = "Start voice call";
      }
      btn.setAttribute("aria-pressed", this.active ? "true" : "false");
      // Guests can't start calls
      btn.disabled = !this.authenticatedValue && !this.active;
    }
    if (this.hasMicBtnTarget) {
      this.micBtnTarget.classList.toggle("muted", this.muted);
      this.micBtnTarget.title = this.muted ? "Unmute" : "Mute";
      this.micBtnTarget.setAttribute("aria-pressed", this.muted ? "true" : "false");
      const micOn = this.micBtnTarget.querySelector(".icon-mic");
      const micOff = this.micBtnTarget.querySelector(".icon-mic-off");
      if (micOn) micOn.hidden = this.muted;
      if (micOff) micOff.hidden = !this.muted;
    }
    if (this.hasCamBtnTarget) {
      this.camBtnTarget.classList.toggle("on", this.cameraOn);
      this.camBtnTarget.title = this.cameraOn ? "Turn off camera" : "Turn on camera";
      this.camBtnTarget.setAttribute("aria-pressed", this.cameraOn ? "true" : "false");
    }
    if (this.hasVideoGridTarget) {
      const show = this.active && (this.cameraOn || this.watchEls.size > 0);
      this.videoGridTarget.hidden = !show;
    }
  }

  syncParticipantCount(n) {
    if (this.hasParticipantCountTarget) {
      this.participantCountTarget.textContent = String(n);
    }
  }

  setStatus(text) {
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = text || "";
    }
  }

  showNotice(text) {
    if (this.hasNoticeTarget) {
      this.noticeTarget.textContent = text;
      this.noticeTarget.hidden = !text;
      if (text) {
        clearTimeout(this._noticeTimer);
        this._noticeTimer = setTimeout(() => {
          this.noticeTarget.hidden = true;
          this.noticeTarget.textContent = "";
        }, 6000);
      }
      return;
    }
    // Fallback: append a notice into #messages if present.
    const messages = document.getElementById("messages");
    if (messages) {
      const div = document.createElement("div");
      div.className = "notice";
      div.textContent = text;
      messages.appendChild(div);
      messages.scrollTop = messages.scrollHeight;
    } else {
      console.warn("[call]", text);
    }
  }
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
