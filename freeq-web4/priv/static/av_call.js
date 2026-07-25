/**
 * freeq-web4 AV call media plane (MoQ).
 *
 * Lightspeed owns call signaling (start/join/leave TAGMSG via LiveView events).
 * This module owns publish/subscribe, mute, camera, roster polling.
 *
 * Port of freeq-web3 assets/js/av_call.js + av_mesh.js + av_session.js + moq_loader.js
 * adapted for Lightspeed morph patches (no Phoenix LiveView hooks).
 */

const SCRIPTS = [
  "/av/assets/publish-Du5ksDQe.js",
  "/av/assets/watch-CTz_Tjt7.js",
];
const PRELOADS = ["/av/assets/time-D4Xqna_f.js"];

let moqLoaded = false;
let moqLoading = null;

function loadMoqComponents() {
  if (moqLoaded) return Promise.resolve();
  if (moqLoading) return moqLoading;

  moqLoading = new Promise((resolve, reject) => {
    let remaining = SCRIPTS.length;
    let failed = false;

    // Hidden placeholders so custom-element upgrade has a home during define.
    // (Same pattern as freeq-app moq-loader / freeq-web3.)
    if (!document.querySelector("moq-publish")) {
      const placeholder = document.createElement("moq-publish");
      placeholder.style.display = "none";
      placeholder.id = "__moq-placeholder-pub";
      document.body.appendChild(placeholder);
    }
    if (!document.querySelector("moq-watch")) {
      const placeholder = document.createElement("moq-watch");
      placeholder.style.display = "none";
      const canvas = document.createElement("canvas");
      canvas.style.display = "none";
      placeholder.appendChild(canvas);
      placeholder.id = "__moq-placeholder-watch";
      document.body.appendChild(placeholder);
    }

    for (const href of PRELOADS) {
      if (!document.querySelector(`link[href="${href}"]`)) {
        const link = document.createElement("link");
        link.rel = "modulepreload";
        link.crossOrigin = "";
        link.href = href;
        document.head.appendChild(link);
      }
    }

    const finish = async () => {
      if (failed) return;
      try {
        await customElements.whenDefined("moq-publish");
        await customElements.whenDefined("moq-watch");
      } catch {
        /* whenDefined can reject if define never happens — surface below */
      }
      if (!customElements.get("moq-publish")) {
        moqLoading = null;
        reject(new Error("moq-publish custom element did not register"));
        return;
      }
      moqLoaded = true;
      resolve();
    };

    for (const src of SCRIPTS) {
      if (document.querySelector(`script[src="${src}"]`)) {
        remaining -= 1;
        if (remaining === 0) finish();
        continue;
      }
      const script = document.createElement("script");
      script.type = "module";
      script.crossOrigin = "";
      script.src = src;
      script.onload = () => {
        remaining -= 1;
        if (remaining === 0) finish();
      };
      script.onerror = () => {
        if (!failed) {
          failed = true;
          moqLoading = null;
          reject(new Error(`Failed to load MoQ script: ${src}`));
        }
      };
      document.head.appendChild(script);
    }

    if (remaining === 0) finish();
  });

  return moqLoading;
}

function broadcastName(sessionId, nick, instance) {
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
  return (
    String(p.nick || "").toLowerCase() === String(me.nick || "").toLowerCase()
  );
}

function computeParticipantSlots(participants, me, sessionId) {
  return (participants || [])
    .filter((p) => !isSelf(p, me))
    .map((p) => ({
      nick: p.nick,
      broadcastKey: broadcastKey(p.nick, p.instance_id),
      broadcastName: broadcastName(sessionId, p.nick, p.instance_id),
    }));
}

async function fetchSessionDetail(sessionId) {
  const resp = await fetch(`/api/v1/sessions/${encodeURIComponent(sessionId)}`, {
    credentials: "same-origin",
    headers: {
      Accept: "application/json",
      "X-Requested-With": "XMLHttpRequest",
    },
  });
  if (!resp.ok) return null;
  return resp.json();
}

async function fetchAvToken(sessionId) {
  const resp = await fetch(
    `/api/v1/av/sessions/${encodeURIComponent(sessionId)}/token`,
    {
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "X-Requested-With": "XMLHttpRequest",
      },
    },
  );
  if (!resp.ok) return null;
  const data = await resp.json().catch(() => ({}));
  return data.token || null;
}

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

function pushEvent(name, payload) {
  if (window.__freeq && typeof window.__freeq.pushEvent === "function") {
    window.__freeq.pushEvent(name, payload || "");
  }
}

class AvCallController {
  constructor(el) {
    this.el = el;
    this.active = true;
    this.left = false;
    this.sessionId = blankToNull(el.dataset.sessionId);
    this.channel = el.dataset.channel || "";
    this.nick = el.dataset.nick || "";
    this.instance = el.dataset.instance || "";
    this.muted = el.dataset.muted === "true";
    this.cameraOn = el.dataset.camera === "true";
    this.avOrigin = (el.dataset.avOrigin || "").replace(/\/$/, "");
    this.moqToken = blankToNull(el.dataset.moqToken);
    this.pubEl = null;
    this.watchEls = new Map();
    this.pollTimer = null;
    this.previewTimer = null;
    this.statusTimer = null;

    this.localVideo = el.querySelector("#av-local-video");
    this.localTile = el.querySelector("#av-local-tile");
    this.remoteRoot = el.querySelector("#av-remote-tiles");
    this.videoGrid = el.querySelector("#av-video-grid");

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

    this.syncLocalChrome();
    this.ensureMedia("mounted");
  }

  /** Re-bind after Lightspeed morph (same controller, new element or attrs). */
  rebind(el) {
    if (!el || !this.active) return;
    const prevSession = this.sessionId;
    const prevToken = this.moqToken;

    // Preserve media subtrees if morph replaced the panel shell.
    if (el !== this.el) {
      const oldGrid = this.el.querySelector("#av-video-grid");
      const newGrid = el.querySelector("#av-video-grid");
      if (oldGrid && newGrid && oldGrid !== newGrid) {
        newGrid.replaceWith(oldGrid);
      }
      const oldPub = this.el.querySelector("#av-publish-container");
      const newPub = el.querySelector("#av-publish-container");
      if (oldPub && newPub && oldPub !== newPub) {
        newPub.replaceWith(oldPub);
      }
      this.videoGrid?.removeEventListener("click", this.onTileClick);
      this.videoGrid?.removeEventListener("keydown", this.onTileKeydown);
      this.el = el;
      this.localVideo = el.querySelector("#av-local-video") || this.localVideo;
      this.localTile = el.querySelector("#av-local-tile") || this.localTile;
      this.remoteRoot = el.querySelector("#av-remote-tiles") || this.remoteRoot;
      this.videoGrid = el.querySelector("#av-video-grid") || this.videoGrid;
      this.videoGrid?.addEventListener("click", this.onTileClick);
      this.videoGrid?.addEventListener("keydown", this.onTileKeydown);
    }

    this.channel = el.dataset.channel || this.channel;
    this.nick = el.dataset.nick || this.nick;
    this.instance = el.dataset.instance || this.instance;
    this.muted = el.dataset.muted === "true";
    this.avOrigin = (el.dataset.avOrigin || this.avOrigin || "").replace(
      /\/$/,
      "",
    );
    this.sessionId = blankToNull(el.dataset.sessionId) || this.sessionId;
    const tok = blankToNull(el.dataset.moqToken);
    if (tok) this.moqToken = tok;

    const camera = el.dataset.camera === "true";
    if (camera !== this.cameraOn) {
      this.cameraOn = camera;
      this.onCameraChanged();
    }
    this.applyMute();
    this.syncLocalChrome();

    if (this.moqToken && this.moqToken !== prevToken) {
      this.applyMoqUrl();
      // TAGMSG token often arrives after mount; kick media once we have it.
      if (!this.pubEl) this.ensureMedia("token-updated");
    }
    if (this.sessionId && this.sessionId !== prevSession) {
      this.ensureMedia("updated-session");
    } else if (this.sessionId && !this.pubEl) {
      this.ensureMedia("updated-retry");
    }
  }

  destroy() {
    this.active = false;
    this.videoGrid?.removeEventListener("click", this.onTileClick);
    this.videoGrid?.removeEventListener("keydown", this.onTileKeydown);
    this.teardown();
    if (!this.left && this.channel && this.sessionId) {
      // Server also leaves on WS close; best-effort client signal.
      pushEvent("av_leave", "");
    }
  }

  handleTileClick(e) {
    const tile = e.target?.closest?.(".av-tile");
    if (!tile || !this.el.contains(tile)) return;
    if (e.target?.closest?.("button, a, input, select, textarea")) return;
    this.toggleTileEnlarged(tile);
  }

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
  }

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
    // Never dial MoQ without a JWT. Tokenless connects still work on the
    // server in migration mode, but they race with the tokened dial and
    // leave half-closed WebSocket streams (fatal error + ReadableStream
    // enqueue spam). Wait for TAGMSG / REST token first.
    if (!this.moqToken) {
      this.setLocalStatus("waiting for media token…");
      this.fetchTokenSoon(this.sessionId);
      return;
    }
    if (!this.pubEl) this.startMedia(reason);
  }

  moqUrl() {
    // Always use the ws(s): scheme — never https:. The MoQ JS client races
    // WebTransport vs WebSocket; WebTransport only accepts https: and the
    // freeq SFU's WT path is known-broken (see freeq-app CallPanel). Forcing
    // wss:/ws: makes WebTransport fail-fast so WebSocket wins cleanly.
    const origin = (window.FREEQ_AV_ORIGIN || this.avOrigin || "").replace(
      /\/$/,
      "",
    );
    let base;
    if (origin) {
      try {
        const u = new URL(origin);
        const wsProto =
          u.protocol === "https:" || u.protocol === "wss:" ? "wss:" : "ws:";
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

  applyMoqUrl() {
    if (!this.moqToken) return;
    const url = this.moqUrl();
    if (this.pubEl && this.pubEl.getAttribute("url") !== url) {
      this.stopPublishEl();
      this.buildPublishEl(this.cameraOn);
    }
    for (const el of this.watchEls.values()) {
      if (el.getAttribute("url") !== url) el.setAttribute("url", url);
    }
  }

  async startMedia(reason) {
    if (!this.active || !this.sessionId || !this.nick || this.pubEl) return;
    if (!this.moqToken) {
      console.log("[av] startMedia deferred — no MoQ token yet", reason);
      return;
    }
    if (this._startingMedia) return;
    this._startingMedia = true;
    this._publishHealthRetried = false;
    console.log(
      "[av] startMedia",
      reason,
      this.sessionId,
      this.moqUrl().replace(/jwt=[^&]+/, "jwt=…"),
    );

    try {
      try {
        await loadMoqComponents();
      } catch (e) {
        console.error("[av] MoQ load failed:", e);
        this.setLocalStatus("media load failed");
        return;
      }

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

      if (!this.active || this.pubEl || !this.moqToken) return;

      // Probe that blob: AudioWorklets are allowed before dialing MoQ.
      // moq-publish loads its capture worklet the same way; CSP without
      // `blob:` in script-src/worker-src (or a SW intercepting blob:) yields
      // AbortError: Unable to load a worklet's module. — and no audio.
      try {
        const probeCode =
          'registerProcessor("freeq-probe", class extends AudioWorkletProcessor { process(){ return false; } });';
        const probeUrl = URL.createObjectURL(
          new Blob([probeCode], { type: "application/javascript" }),
        );
        const actx = new AudioContext();
        try {
          await actx.audioWorklet.addModule(probeUrl);
        } finally {
          URL.revokeObjectURL(probeUrl);
          await actx.close().catch(() => {});
        }
      } catch (e) {
        console.error(
          "[av] AudioWorklet probe failed — CSP must allow blob: in script-src/worker-src; service workers must not intercept blob: URLs",
          e,
        );
        this.setLocalStatus("worklet blocked");
        return;
      }

      this.buildPublishEl(this.cameraOn);
      this.beginLocalPreviewPoll();
      this.beginStatusPoll();
    } finally {
      this._startingMedia = false;
    }
  }

  onCameraChanged() {
    if (this.pubEl) {
      this.stopPublishEl();
      this._publishHealthRetried = false;
      this.buildPublishEl(this.cameraOn);
    }
    this.syncLocalChrome();
    this.updateLocalPreview();
  }

  buildPublishEl(withVideo) {
    const container = this.el.querySelector("#av-publish-container");
    if (!container || !this.sessionId || !this.nick || !this.moqToken) return;

    container.innerHTML = "";
    const pub = document.createElement("moq-publish");
    // Match freeq-app CallPanel: append first, then configure.
    // connectedCallback enables the broadcast; attrs then start capture once.
    // (Setting source while disconnected still works, but the production path
    // is connect → url → name → invisible → mute → source.)
    container.appendChild(pub);
    this.pubEl = pub;

    const name = broadcastName(this.sessionId, this.nick, this.instance);
    const url = this.moqUrl();
    pub.setAttribute("url", url);
    pub.setAttribute("name", name);
    // invisible BEFORE source so getUserMedia is audio-only when camera off.
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
    this.setLocalStatus(withVideo ? "camera" : "connecting audio…");
    setTimeout(() => this.updateLocalPreview(), 400);
    setTimeout(() => this.updateLocalPreview(), 1200);
    // moq-publish may abort its first AudioWorklet load when it re-acquires
    // the preferred mic (spawn error AbortError: Unable to load a worklet's
    // module). That is usually recovered internally; if the mic track never
    // lands, rebuild once.
    this.schedulePublishHealthCheck(pub, withVideo);
  }

  schedulePublishHealthCheck(pub, withVideo) {
    if (this._publishHealthTimer) clearTimeout(this._publishHealthTimer);
    this._publishHealthTimer = setTimeout(() => {
      this._publishHealthTimer = null;
      if (!this.active || this.pubEl !== pub) return;
      let track = null;
      try {
        const src = pub.audio?.peek?.()?.source?.peek?.();
        track = src?.track || src || null;
      } catch {
        /* signals may not be exposed on every moq build */
      }
      if (track && track.readyState === "live") {
        this.setLocalStatus(withVideo ? "camera" : "audio live");
        return;
      }
      if (this._publishHealthRetried) {
        console.warn(
          "[av] mic track not live after publish — audio may be silent (worklet/CSP/permission)",
        );
        this.setLocalStatus("audio failed");
        return;
      }
      this._publishHealthRetried = true;
      console.warn("[av] mic track not live — rebuilding publisher once");
      this.stopPublishEl();
      this.buildPublishEl(withVideo);
    }, 2500);
  }

  stopPublishEl() {
    const pub = this.pubEl;
    if (!pub) return;
    // Tear down without bouncing through url="" (that dials a tokenless
    // reconnect race before remove() runs).
    try {
      pub.muted = true;
      pub.paused = true;
    } catch {
      /* element may already be inert */
    }
    pub.removeAttribute("source");
    pub.removeAttribute("name");
    pub.removeAttribute("url");
    pub.remove();
    this.pubEl = null;
    if (this.localVideo) {
      this.localVideo.srcObject = null;
      this.localVideo.hidden = true;
    }
  }

  applyMute() {
    const pub = this.pubEl;
    if (!pub) return;
    if (this.muted) pub.setAttribute("muted", "");
    else pub.removeAttribute("muted");
    pub.muted = this.muted;
  }

  beginLocalPreviewPoll() {
    if (this.previewTimer) clearInterval(this.previewTimer);
    this.previewTimer = setInterval(() => {
      if (!this.active) return;
      this.updateLocalPreview();
    }, 1000);
  }

  beginStatusPoll() {
    if (this.statusTimer) clearInterval(this.statusTimer);
    this.statusTimer = setInterval(() => {
      if (!this.active) return;
      this.refreshRemoteStatuses();
    }, 800);
  }

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
  }

  setLocalStatus(text) {
    if (!this.localTile) return;
    const label = this.localTile.querySelector(".av-tile-label");
    if (!label) return;
    const bits = ["You"];
    if (this.muted) bits.push("muted");
    else if (text) bits.push(text);
    else if (!this.cameraOn) bits.push("audio");
    label.textContent = bits.join(" · ");
  }

  syncLocalChrome() {
    if (!this.localTile) return;
    this.localTile.classList.toggle("is-muted", !!this.muted);
    this.localTile.classList.toggle("is-camera-on", !!this.cameraOn);
    this.localTile.classList.toggle("has-audio", !!this.pubEl);
    this.setLocalStatus(
      this.cameraOn ? "camera" : this.pubEl ? "audio live" : "connecting…",
    );
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
        { nick: this.nick, instance: this.instance, did: null },
        this.sessionId,
      );
      this.syncRemoteTiles(slots);
      pushEvent("av_roster", `count=${(data.participants || []).length}`);
    } catch (e) {
      console.warn("[av] roster poll failed:", e);
    }
  }

  syncRemoteTiles(slots) {
    const root = this.remoteRoot || this.el.querySelector("#av-remote-tiles");
    if (!root) return;
    // No token → no media dial. Keep the roster labels, skip MoQ watches.
    if (!this.moqToken) return;

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
      canvas.width = 320;
      canvas.height = 240;
      watchEl.appendChild(canvas);
      watchEl.style.cssText =
        "position:absolute;inset:0;width:100%;height:100%;display:block";
      watchEl.setAttribute("jitter", "80");
      // `reload` re-subscribes when a late publisher announces. Without it a
      // peer who joins after us stays black forever. Do NOT set it before
      // url/name — a reload-on-empty-url loop was observed as:
      //   connected via WebSocket → fatal error → enqueue TypeError (storm).
      watchEl.setAttribute("name", slot.broadcastName);
      watchEl.setAttribute("url", this.moqUrl());
      watchEl.setAttribute("reload", "");
      mount.appendChild(watchEl);
      this.watchEls.set(slot.broadcastKey, watchEl);

      console.log(
        "[av] subscribing to:",
        slot.broadcastName,
        this.moqUrl().replace(/jwt=[^&]+/, "jwt=…"),
      );
    }
  }

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
  }

  destroyWatch(el) {
    if (!el) return;
    try {
      el.paused = true;
    } catch {
      /* ignore */
    }
    // Remove attributes without dialing a bare /av/moq reconnect first.
    el.removeAttribute("reload");
    el.removeAttribute("url");
    el.removeAttribute("name");
    el.remove();
  }

  async fetchTokenSoon(sessionId) {
    if (this.moqToken) return;
    if (this._fetchingToken) return;
    this._fetchingToken = true;
    try {
      await new Promise((r) => setTimeout(r, 400));
      if (this.moqToken || !this.active || this.sessionId !== sessionId) return;

      for (let i = 0; i < 8; i++) {
        if (this.moqToken || !this.active || this.sessionId !== sessionId) return;
        try {
          const tok = await fetchAvToken(sessionId);
          if (tok) {
            this.moqToken = tok;
            console.log("[av] token via REST");
            // Token landed — start media if we deferred, and attach JWT to any
            // existing elements (should be none, but keep apply for safety).
            this.applyMoqUrl();
            if (!this.pubEl) this.startMedia("token-ready");
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
        this.setLocalStatus("no media token");
      }
    } finally {
      this._fetchingToken = false;
    }
  }

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
    if (this._publishHealthTimer) {
      clearTimeout(this._publishHealthTimer);
      this._publishHealthTimer = null;
    }
    this.stopPublishEl();
    for (const el of this.watchEls.values()) this.destroyWatch(el);
    this.watchEls.clear();
    if (this.remoteRoot) this.remoteRoot.innerHTML = "";
  }
}

let controller = null;

function syncAvCall() {
  const el = document.getElementById("av-call-panel");
  if (el) {
    if (controller) controller.rebind(el);
    else controller = new AvCallController(el);
  } else if (controller) {
    controller.left = true;
    controller.destroy();
    controller = null;
  }
}

// Observe morphs and initial load.
//
// Do NOT watch every attribute under the app: moq-publish mutates its own
// attrs/DOM while the capture AudioWorklet is loading, and a full-tree
// attributes observer rebinds mid-load → AudioContext.close() mid-addModule
// → AbortError: Unable to load a worklet's module (silent publisher).
const root = document.getElementById("app") || document.body;
const mo = new MutationObserver((mutations) => {
  let relevant = false;
  for (const m of mutations) {
    if (m.type === "childList") {
      relevant = true;
      break;
    }
    if (
      m.type === "attributes" &&
      m.target &&
      m.target.id === "av-call-panel"
    ) {
      relevant = true;
      break;
    }
  }
  if (!relevant) return;
  // Debounce to one frame after Lightspeed patches.
  if (syncAvCall._raf) return;
  syncAvCall._raf = requestAnimationFrame(() => {
    syncAvCall._raf = 0;
    syncAvCall();
  });
});
mo.observe(root, {
  childList: true,
  subtree: true,
  attributes: true,
  // Only panel data-* matter for rebind; ignore moq-publish/url noise.
  attributeFilter: [
    "data-session-id",
    "data-moq-token",
    "data-muted",
    "data-camera",
    "data-nick",
    "data-instance",
    "data-channel",
    "data-av-origin",
    "data-authenticated",
    "class",
  ],
});
queueMicrotask(syncAvCall);

window.__freeqAv = { sync: syncAvCall };
