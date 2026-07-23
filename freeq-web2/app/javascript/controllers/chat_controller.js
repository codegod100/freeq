import { Controller } from "@hotwired/stimulus";
import consumer from "../channels/consumer";
import CableReady from "cable_ready";
import StimulusReflex from "stimulus_reflex";
import * as dm from "../dm.js";
import { hydrateLinkEmbeds } from "../link_embeds.js";
// Client-side chat controller: ChatChannel live updates, reactions, replies.
export default class ChatController extends Controller {
  connect() {
    StimulusReflex.useReflex(this);
    this.setupChannel();
    this.setupReactions();
    this.setupReplies();
    this.setupSidebar();
    this.setupTopicEdit();
    this.setupTabComplete();
    this.setupDm();
    this.setupUpload();
    this.hydrateReplyBadges();
    this.hydrateLinkEmbeds();
    this.localizeTimes();
    this.scrollToBottom();

    // Focus the composer — safer than the autofocus attribute, which the
    // browser blocks when another element already has focus (Turbo keeps
    // focus across navigations).
    const input = document.getElementById("message-input");
    if (input && !/Mobi|Android/i.test(navigator.userAgent)) input.focus();

    this._onReaction = (ev) => {
      const d = ev.detail || {};
      this.applyReaction(d.msgid, d.emoji, d.nick, !!d.added);
    };
    this.element.addEventListener("freeq:reaction", this._onReaction);
  }

  setupChannel() {
    const channel = this.element.dataset.channel;
    if (!channel) return;
    this.channel = "#" + channel;
    this.bare = channel;

    if (this.element.dataset.authHandle) {
      document.body.setAttribute("data-auth-handle", this.element.dataset.authHandle);
    }

    this.subscription = consumer.subscriptions.create(
      { channel: "ChatChannel", room: channel },
      {
        received: (data) => {
          if (data && data.cableReady) {
            this.filterDupes(data.operations);
            CableReady.perform(data.operations);
            this.hydrateReplyBadges();
            // Live PRIVMSG rows arrive as ENC3: ciphertext — decrypt in place.
            this.decryptDmRows();
            this.hydrateLinkEmbeds();
            this.localizeTimes();
            this.scrollToBottom();
          }
        },
        // ActionCable (browser↔Rails) only — IRC status is pushed from the
        // BFF via CableReady when the upstream WS reaches :ready.
        connected: () => {
          // Don't claim "connected" here; that races ChatChannel#subscribed
          // which snapshots IRC state (often still connecting) and was
          // leaving the UI stuck if no later status broadcast fired.
        },
        disconnected: () => this.setStatus("reconnecting…", false),
      }
    );
  }

  disconnect() {
    this.subscription?.unsubscribe();
    if (this._onReaction) {
      this.element.removeEventListener("freeq:reaction", this._onReaction);
    }
    this._embedObserver?.disconnect();
    this._embedObserver = null;
    clearTimeout(this._embedObsTimer);
    this.teardownUpload?.();
  }

  // ── Image upload (+ button, paste, optional drop) ───────────────────

  setupUpload() {
    const MAX_BYTES = 10 * 1024 * 1024;
    const attachBtn = document.getElementById("attach-btn");
    const fileInput = document.getElementById("file-input");
    const input = document.getElementById("message-input");
    const preview = document.getElementById("upload-preview");
    const previewImg = document.getElementById("upload-preview-img");
    const previewName = document.getElementById("upload-preview-name");
    const previewStatus = document.getElementById("upload-preview-status");
    const previewCancel = document.getElementById("upload-preview-cancel");
    if (!attachBtn || !fileInput || !input) return;

    let objectUrl = null;
    let uploading = false;

    const clearPreview = () => {
      if (objectUrl) {
        URL.revokeObjectURL(objectUrl);
        objectUrl = null;
      }
      if (preview) preview.hidden = true;
      if (previewImg) previewImg.removeAttribute("src");
      if (previewName) previewName.textContent = "";
      if (previewStatus) {
        previewStatus.textContent = "";
        previewStatus.classList.remove("error");
      }
      fileInput.value = "";
      uploading = false;
      attachBtn.disabled = false;
    };

    const showPreview = (file, statusText) => {
      if (!preview) return;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
      objectUrl = file.type.startsWith("image/")
        ? URL.createObjectURL(file)
        : null;
      if (previewImg) {
        if (objectUrl) {
          previewImg.src = objectUrl;
          previewImg.hidden = false;
        } else {
          previewImg.hidden = true;
        }
      }
      if (previewName) previewName.textContent = file.name || "image";
      if (previewStatus) {
        previewStatus.textContent = statusText || "";
        previewStatus.classList.remove("error");
      }
      preview.hidden = false;
    };

    const setStatus = (text, isError = false) => {
      if (!previewStatus) return;
      previewStatus.textContent = text;
      previewStatus.classList.toggle("error", !!isError);
    };

    const authDid = () =>
      this.element.dataset.authDid ||
      document.body.getAttribute("data-auth-did") ||
      "";

    const channelName = () => {
      const isDm = document
        .getElementById("send-form")
        ?.dataset?.isDm === "true";
      if (isDm) return "";
      const bare =
        this.bare ||
        this.element.dataset.channel ||
        this.channel?.replace(/^#/, "") ||
        "";
      return bare ? `#${bare.replace(/^#/, "")}` : "";
    };

    const sendUrlMessage = (url) => {
      const caption = (input.value || "").trim();
      input.value = caption ? `${caption} ${url}` : url;
      const form = document.getElementById("send-form");
      if (form) {
        // StimulusReflex listens for submit — requestSubmit triggers it.
        if (typeof form.requestSubmit === "function") form.requestSubmit();
        else form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      }
    };

    const uploadFile = async (file) => {
      if (!file) return;
      if (uploading) return;

      if (!authDid().startsWith("did:")) {
        setStatus("Sign in to upload images", true);
        showPreview(file, "Sign in to upload images");
        previewStatus?.classList.add("error");
        return;
      }
      if (file.size > MAX_BYTES) {
        showPreview(file, "File too large (max 10MB)");
        setStatus("File too large (max 10MB)", true);
        return;
      }
      // Screenshots / photos — accept any image/* (incl. empty type from some OS).
      if (file.type && !file.type.startsWith("image/")) {
        showPreview(file, `Unsupported type: ${file.type}`);
        setStatus(`Unsupported type: ${file.type}`, true);
        return;
      }

      uploading = true;
      attachBtn.disabled = true;
      showPreview(file, "Uploading…");

      try {
        const fd = new FormData();
        fd.append("file", file, file.name || "screenshot.png");
        const ch = channelName();
        if (ch) fd.append("channel", ch);
        const caption = (input.value || "").trim();
        if (caption) fd.append("alt", caption);

        const res = await fetch("/upload", {
          method: "POST",
          body: fd,
          credentials: "same-origin",
        });
        let data = {};
        try {
          data = await res.json();
        } catch (_) {
          data = { error: await res.text() };
        }
        if (!res.ok) {
          throw new Error(data.error || data.message || `Upload failed (${res.status})`);
        }
        if (!data.url) throw new Error("Upload succeeded but no URL returned");

        setStatus("Sending…");
        sendUrlMessage(data.url);
        clearPreview();
      } catch (e) {
        console.error("upload", e);
        setStatus(e.message || "Upload failed", true);
        uploading = false;
        attachBtn.disabled = false;
      }
    };

    const onAttachClick = () => {
      if (!authDid().startsWith("did:")) {
        showPreview(
          new File([], "image"),
          "Sign in to upload images"
        );
        // Fake empty file looks odd — just status toast via preview strip.
        if (previewImg) previewImg.hidden = true;
        if (previewName) previewName.textContent = "Upload";
        setStatus("Sign in to upload images", true);
        if (preview) preview.hidden = false;
        return;
      }
      fileInput.click();
    };

    const onFileChange = () => {
      const file = fileInput.files && fileInput.files[0];
      if (file) uploadFile(file);
    };

    const onPaste = (e) => {
      const items = e.clipboardData && e.clipboardData.items;
      if (!items) return;
      for (const item of items) {
        if (item.kind === "file" && (!item.type || item.type.startsWith("image/"))) {
          const file = item.getAsFile();
          if (file) {
            e.preventDefault();
            uploadFile(file);
            return;
          }
        }
      }
    };

    // Drag-drop onto the composer / message pane (lightweight).
    const onDragOver = (e) => {
      if (e.dataTransfer && [...e.dataTransfer.types].includes("Files")) {
        e.preventDefault();
      }
    };
    const onDrop = (e) => {
      if (!e.dataTransfer?.files?.length) return;
      e.preventDefault();
      const file = e.dataTransfer.files[0];
      if (file) uploadFile(file);
    };

    attachBtn.addEventListener("click", onAttachClick);
    fileInput.addEventListener("change", onFileChange);
    input.addEventListener("paste", onPaste);
    this.element.addEventListener("paste", onPaste);
    this.element.addEventListener("dragover", onDragOver);
    this.element.addEventListener("drop", onDrop);
    previewCancel?.addEventListener("click", clearPreview);

    this.teardownUpload = () => {
      attachBtn.removeEventListener("click", onAttachClick);
      fileInput.removeEventListener("change", onFileChange);
      input.removeEventListener("paste", onPaste);
      this.element.removeEventListener("paste", onPaste);
      this.element.removeEventListener("dragover", onDragOver);
      this.element.removeEventListener("drop", onDrop);
      previewCancel?.removeEventListener("click", clearPreview);
      clearPreview();
    };
  }

  setStatus(text, connected) {
    const status = document.getElementById("status");
    if (!status) return;
    status.classList.toggle("connected", !!connected);
    status.innerHTML = '<span class="dot"></span> <span>' + text + "</span>";
  }

  scrollToBottom() {
    const el = document.getElementById("messages");
    if (el) el.scrollTop = el.scrollHeight;
  }

  /**
   * Rewrite .ts[data-ts] and .date-sep[data-ts] into the browser's local
   * timezone. Server still emits UTC as a no-JS fallback.
   */
  localizeTimes() {
    const root = document.getElementById("messages") || this.element;
    if (!root) return;

    root.querySelectorAll(".ts[data-ts]").forEach((el) => {
      const sec = parseInt(el.dataset.ts, 10);
      if (!Number.isFinite(sec)) return;
      const d = new Date(sec * 1000);
      el.textContent = d.toLocaleTimeString(undefined, {
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hour12: false,
      });
    });

    // Rebuild date separators from message timestamps in *local* calendar days.
    this.rebuildDateSeparators(root);
  }

  localDayKey(d) {
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${day}`;
  }

  formatLocalDateLabel(d) {
    const now = new Date();
    const today = this.localDayKey(now);
    const key = this.localDayKey(d);
    if (key === today) return "Today";
    const yest = new Date(now);
    yest.setDate(yest.getDate() - 1);
    if (key === this.localDayKey(yest)) return "Yesterday";
    return d.toLocaleDateString(undefined, {
      weekday: "long",
      month: "long",
      day: "numeric",
      year: "numeric",
    });
  }

  rebuildDateSeparators(root) {
    // Drop server-rendered seps; re-insert based on local day boundaries.
    root.querySelectorAll(".date-sep").forEach((el) => el.remove());

    let lastDay = null;
    const children = Array.from(root.children);
    for (const node of children) {
      const tsEl = node.querySelector?.(".ts[data-ts]");
      if (!tsEl) continue;
      const sec = parseInt(tsEl.dataset.ts, 10);
      if (!Number.isFinite(sec)) continue;
      const d = new Date(sec * 1000);
      const day = this.localDayKey(d);
      if (day === lastDay) continue;
      lastDay = day;
      const sep = document.createElement("div");
      sep.className = "date-sep";
      sep.dataset.ts = String(sec);
      sep.dataset.day = day;
      sep.setAttribute("role", "separator");
      const span = document.createElement("span");
      span.textContent = this.formatLocalDateLabel(d);
      sep.appendChild(span);
      node.parentNode.insertBefore(sep, node);
    }
  }

  // Strip CableReady append ops whose HTML carries a data-msgid already
  // present in #messages. Prevents REST scrollback + live echo / chathistory
  // batch from double-rendering the same message.
  filterDupes(operations) {
    if (!Array.isArray(operations)) return;
    const messages = document.getElementById("messages");
    if (!messages) return;
    const existing = new Set(
      Array.from(messages.querySelectorAll("[data-msgid]")).map((el) =>
        el.getAttribute("data-msgid")
      )
    );
    for (let i = operations.length - 1; i >= 0; i--) {
      const op = operations[i];
      if (op.operation !== "append") continue;
      const html = op.html || "";
      const match = html.match(/data-msgid="([^"]+)"/);
      if (match && existing.has(match[1])) {
        operations.splice(i, 1);
      }
    }
  }

  // ── Replies ──────────────────────────────────────────────────────────

  setupReplies() {
    const self = this;

    window.startReply = (msgid) => {
      msgid = String(msgid || "");
      if (!msgid) return;
      const row = document.querySelector(
        `.msg[data-msgid="${CSS.escape(msgid)}"]`
      );
      const nick = row?.dataset?.nick || "message";
      const text = (row?.dataset?.text || "").replace(/\s+/g, " ").slice(0, 80);
      const input = document.getElementById("reply-to-input");
      if (input) input.value = msgid;
      const banner = document.getElementById("reply-banner");
      if (banner) {
        banner.innerHTML =
          '<span class="reply-banner-label">Replying to ' +
          escapeHtml(nick) +
          '</span><span class="reply-banner-text">' +
          escapeHtml(text) +
          '</span><button type="button" class="reply-banner-cancel" title="Cancel" onclick="window.cancelReply()">×</button>';
      }
      document.getElementById("message-input")?.focus();
    };

    window.cancelReply = () => {
      const input = document.getElementById("reply-to-input");
      if (input) input.value = "";
      const banner = document.getElementById("reply-banner");
      if (banner) banner.innerHTML = "";
    };

    window.scrollToMessage = (msgid) => {
      msgid = String(msgid || "");
      const row = document.querySelector(
        `.msg[data-msgid="${CSS.escape(msgid)}"]`
      );
      if (!row) return;
      row.scrollIntoView({ behavior: "smooth", block: "center" });
      row.classList.add("highlight");
      setTimeout(() => row.classList.remove("highlight"), 1200);
    };

    // Clear reply target after a successful send is handled server-side via
    // CableReady; also clear on Escape.
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape") window.cancelReply();
    });

    // After StimulusReflex send, the form may still have reply_to; server clears
    // via CableReady. Also clear client-side on submit so a failed clear doesn't stick.
    const form = document.getElementById("send-form");
    form?.addEventListener("submit", () => {
      // Leave reply_to set until after serialize; clear after a tick so the
      // reflex still receives the field.
      setTimeout(() => {
        // Server CableReady also clears; this is a belt-and-suspenders for UX.
      }, 0);
    });

    // ── Editing ──────────────────────────────────────────────────────

    window.startEdit = (msgid) => {
      msgid = String(msgid || "");
      if (!msgid) return;
      const row = document.querySelector(
        `.msg[data-msgid="${CSS.escape(msgid)}"]`
      );
      if (!row) return;
      const input = document.getElementById("message-input");
      if (!input) return;
      input.value = row.dataset.text || "";
      input.focus();
      const editInput = document.getElementById("edit-to-input");
      if (editInput) editInput.value = msgid;
      const replyInput = document.getElementById("reply-to-input");
      if (replyInput) replyInput.value = "";
      const banner = document.getElementById("reply-banner");
      if (banner) {
        banner.innerHTML =
          '<span class="reply-banner-label">Editing message</span>' +
          '<span class="reply-banner-spacer"></span>' +
          '<button type="button" class="reply-banner-delete" title="Delete message" ' +
          'onclick="window.deleteEditingMessage()">Delete</button>' +
          '<button type="button" class="reply-banner-cancel" title="Cancel" onclick="window.cancelEdit()">×</button>';
      }
    };

    window.cancelEdit = () => {
      const input = document.getElementById("message-input");
      if (input) input.value = "";
      const editInput = document.getElementById("edit-to-input");
      if (editInput) editInput.value = "";
      const banner = document.getElementById("reply-banner");
      if (banner) banner.innerHTML = "";
    };

    window.deleteEditingMessage = async () => {
      const editInput = document.getElementById("edit-to-input");
      const msgid = (editInput && editInput.value) || "";
      if (!msgid) return;
      if (!window.confirm("Delete this message?")) return;

      const bare =
        self.bare ||
        self.element?.dataset?.channel ||
        (self.channel || "").replace(/^#/, "");
      // Channel path segment is bare name; DMs use the nick as data-channel.
      const target = bare;
      if (!target) return;

      try {
        const payload = new FormData();
        payload.append("msgid", msgid);
        const res = await fetch(
          `/chat/${encodeURIComponent(target)}/delete`,
          {
            method: "POST",
            body: payload,
            credentials: "same-origin",
          }
        );
        if (!res.ok) {
          const err = await res.json().catch(() => ({}));
          console.error("delete failed", res.status, err);
          return;
        }
        // Optimistic remove — server echo also removes via CableReady.
        const row = document.querySelector(
          `.msg[data-msgid="${CSS.escape(msgid)}"]`
        );
        row?.remove();
        window.cancelEdit();
      } catch (e) {
        console.error("deleteEditingMessage", e);
      }
    };
  }

  // Fill in reply badge nick/text from the parent .msg[data-msgid] if present.
  hydrateReplyBadges() {
    document.querySelectorAll(".reply-badge[data-reply-to]").forEach((badge) => {
      const mid = badge.getAttribute("data-reply-to");
      if (!mid) return;
      const parent = document.querySelector(
        `.msg[data-msgid="${CSS.escape(mid)}"]`
      );
      if (!parent) return;
      const nickEl = badge.querySelector(".reply-nick");
      const textEl = badge.querySelector(".reply-text");
      if (nickEl && parent.dataset.nick) nickEl.textContent = parent.dataset.nick;
      if (textEl && parent.dataset.text) {
        const t = parent.dataset.text.replace(/\s+/g, " ");
        textEl.textContent = t.length > 80 ? t.slice(0, 80) + "…" : t;
      }
    });
  }

  // YouTube / Bluesky / OpenGraph cards under message text.
  hydrateLinkEmbeds() {
    const root = document.getElementById("messages") || this.element;
    if (!root) return;
    // Fire-and-forget — OG/Bluesky fetches are async; don't block scroll.
    hydrateLinkEmbeds(root).catch((e) =>
      console.warn("hydrateLinkEmbeds", e)
    );
    // Catch rows appended outside our CableReady path (or after a late
    // morph). Cheap: hydrateLinkEmbeds no-ops rows that already have cards.
    if (!this._embedObserver && typeof MutationObserver !== "undefined") {
      this._embedObserver = new MutationObserver(() => {
        clearTimeout(this._embedObsTimer);
        this._embedObsTimer = setTimeout(() => {
          hydrateLinkEmbeds(root).catch(() => {});
        }, 80);
      });
      this._embedObserver.observe(root, { childList: true, subtree: true });
    }
  }

  // ── Reactions ────────────────────────────────────────────────────────

  setupReactions() {
    const self = this;

    window.openReactPicker = (msgid) => {
      const picker = document.getElementById("react-picker");
      if (!picker) return;
      const emojis = ["👍", "❤️", "😂", "🎉", "🔥", "👀", "💯", "✨"];
      picker.innerHTML = emojis
        .map((e) => {
          const mid = String(msgid).replace(/'/g, "\\'");
          const es = e.replace(/'/g, "\\'");
          return (
            '<button type="button" onclick="window.toggleReaction(\'' +
            mid +
            "','" +
            es +
            "');document.getElementById('react-picker').classList.remove('open')\">" +
            e +
            "</button>"
          );
        })
        .join("");
      picker.classList.add("open");
    };

    window.toggleReaction = async (msgid, emoji) => {
      const channel = self.bare || self.channel.replace(/^#/, "");
      const el = document.querySelector(
        `.reaction-chip[data-emoji="${CSS.escape(emoji)}"][data-msgid="${CSS.escape(msgid)}"]`
      );
      const mine = el?.classList.contains("mine");
      const path = mine ? "unreact" : "react";
      const me = self.myReactionNick();
      const payload = new FormData();
      payload.append("msgid", msgid);
      payload.append("emoji", emoji);
      try {
        const res = await fetch(`/chat/${encodeURIComponent(channel)}/${path}`, {
          method: "POST",
          headers: {
            "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')
              .content,
          },
          body: payload,
          credentials: "same-origin",
        });
        if (!res.ok) {
          console.error("toggleReaction HTTP", res.status);
          return;
        }
        // Apply immediately — freeq:reaction may never arrive if ActionCable
        // is down or session-mismatched. Server echo re-applies idempotently.
        let nick = me;
        try {
          const data = await res.json();
          if (data && data.nick) nick = data.nick;
        } catch (_) {
          /* non-JSON ok */
        }
        if (nick) self.applyReaction(msgid, emoji, nick, !mine);
      } catch (e) {
        console.error("toggleReaction", e);
      }
    };
  }

  myReactionNick() {
    return (
      this.element.dataset.authNick ||
      this.element.dataset.authHandle ||
      document.body.getAttribute("data-auth-handle") ||
      ""
    );
  }

  applyReaction(msgid, emoji, nick, added) {
    msgid = String(msgid || "");
    emoji = String(emoji || "");
    nick = String(nick || "");
    if (!msgid || !emoji) return;
    const row = document.querySelector(
      `.msg[data-msgid="${CSS.escape(msgid)}"]`
    );
    if (!row) return;
    let container = row.querySelector(".reactions");
    if (!container) {
      container = document.createElement("span");
      container.className = "reactions";
      (row.querySelector(".body") || row).appendChild(container);
    }
    let chip = container.querySelector(
      `.reaction-chip[data-emoji="${CSS.escape(emoji)}"]`
    );
    const me = this.myReactionNick();
    if (!chip && added) {
      chip = document.createElement("button");
      chip.type = "button";
      chip.className = "reaction-chip";
      chip.dataset.emoji = emoji;
      chip.dataset.msgid = msgid;
      chip.onclick = () => window.toggleReaction(msgid, emoji);
      container.insertBefore(chip, container.querySelector(".react-btn"));
    }
    if (!chip) return;
    // Treat handle / preferred nick / current nick as the same person so
    // optimistic + server echo don't double-count.
    const aliases = new Set(
      [nick, me, this.element.dataset.authHandle, this.element.dataset.authNick]
        .filter(Boolean)
        .map((s) => s.toLowerCase())
    );
    let nicks = (chip.getAttribute("title") || "")
      .split(", ")
      .filter(Boolean)
      .filter((n) => !aliases.has(n.toLowerCase()));
    if (added) nicks.push(nick);
    if (nicks.length === 0) {
      chip.remove();
      return;
    }
    chip.setAttribute("title", nicks.join(", "));
    chip.textContent = nicks.length <= 1 ? emoji : emoji + " " + nicks.length;
    if (me) {
      const mine = nicks.some((n) => aliases.has(n.toLowerCase()));
      chip.classList.toggle("mine", mine);
    }
  }

  setupSidebar() {
    const sidebar = () => document.getElementById("sidebar");
    const members = () => document.getElementById("member-panel");
    const scrim = () => document.getElementById("drawer-scrim");

    const syncScrim = () => {
      const open =
        sidebar()?.classList.contains("open") ||
        members()?.classList.contains("open");
      scrim()?.classList.toggle("open", !!open);
      document.body.style.overflow = open ? "hidden" : "";
    };

    window.closeDrawers = () => {
      sidebar()?.classList.remove("open");
      members()?.classList.remove("open");
      syncScrim();
    };

    window.toggleSidebar = () => {
      const s = sidebar();
      const m = members();
      if (!s) return;
      const willOpen = !s.classList.contains("open");
      m?.classList.remove("open");
      s.classList.toggle("open", willOpen);
      syncScrim();
    };

    window.toggleMembers = () => {
      const s = sidebar();
      const m = members();
      if (!m) return;
      const willOpen = !m.classList.contains("open");
      s?.classList.remove("open");
      m.classList.toggle("open", willOpen);
      syncScrim();
    };

    // Section collapse (MY CHANNELS / ALL / DMs).
    document.querySelectorAll(".sidebar-toggle").forEach((el) => {
      el.addEventListener("click", () => {
        const id = el.dataset.target;
        const list = id && document.getElementById(id);
        if (!list) return;
        const hidden = list.style.display === "none";
        list.style.display = hidden ? "" : "none";
        el.classList.toggle("collapsed", !hidden);
      });
    });

    // Tapping a channel / DM navigates — close the sheet first so the
    // transition feels intentional rather than a full-page jump under a drawer.
    sidebar()?.addEventListener("click", (ev) => {
      const a = ev.target.closest("a.sidebar-channel-link");
      if (a) window.closeDrawers();
    });

    document.addEventListener("keydown", (ev) => {
      if (ev.key === "Escape") window.closeDrawers();
    });

    // Swipe-from-edge would be nice later; backdrop tap is enough for v1.
  }

  // ── Topic editing ─────────────────────────────────────────────────

  // Click the topic to edit it inline. Enter submits (ChatReflex#set_topic
  // sends TOPIC upstream; the echo updates #channel-topic). Esc/blur cancels.
  setupTopicEdit() {
    const span = document.getElementById("channel-topic");
    const form = document.getElementById("topic-form");
    const input = document.getElementById("topic-input");
    if (!span || !form || !input) return;

    const open = () => {
      const current = span.textContent.trim();
      // "add topic" is the empty-state placeholder, not a real topic.
      input.value = current === "add topic" ? "" : current;
      span.style.display = "none";
      form.style.display = "";
      input.focus();
      input.select();
    };
    const close = () => {
      form.style.display = "none";
      span.style.display = "";
    };

    span.addEventListener("click", open);
    form.addEventListener("submit", () => close());
    input.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        close();
      }
    });
    input.addEventListener("blur", () => close());
  }

  // ── Tab completion ───────────────────────────────────────────────────

  setupTabComplete() {
    const input = document.getElementById("message-input");
    if (!input) return;

    // Cycle state survives across Tab presses until the user types or moves
    // the caret outside the completed token.
    // { matches, index, wordStart, insertedLen, basePartial }
    this._tabCycle = null;

    input.addEventListener("keydown", (e) => {
      if (e.key !== "Tab") {
        this._tabCycle = null;
        return;
      }
      e.preventDefault();

      const pos = input.selectionStart ?? 0;
      const value = input.value;
      const before = value.substring(0, pos);
      const after = value.substring(pos);

      // Continuing a cycle: only if the prior insertion is still intact.
      if (this._tabCycle) {
        const { wordStart, insertedLen, matches, inserted } = this._tabCycle;
        const stillThere =
          pos >= wordStart &&
          pos <= wordStart + insertedLen &&
          value.substring(wordStart, wordStart + insertedLen) === inserted;
        if (stillThere) {
          this._tabCycle.index =
            (this._tabCycle.index + 1) % matches.length;
          this.applyTabMatch(input, wordStart, after, this._tabCycle);
          return;
        }
        this._tabCycle = null;
      }

      // Fresh completion: word before caret, optional leading "@".
      // IRC nicks: letter/digit/._- ; leading @ is the mention prefix.
      const m = before.match(/(?:^|[\s,])(@?[\w.\-]*)$/);
      if (!m) return;

      const token = m[1];
      const wordStart = before.length - token.length;
      const hasAt = token.startsWith("@");
      const partial = (hasAt ? token.slice(1) : token).toLowerCase();

      const nicks = this.getChannelNicks();
      if (!nicks.length) return;

      const matches =
        partial === ""
          ? nicks.slice()
          : nicks.filter((n) => n.toLowerCase().startsWith(partial));
      if (!matches.length) return;

      // Start-of-line (after optional @) → "nick: "; mid-line → keep @ if typed.
      const isStart = wordStart === 0;
      this._tabCycle = {
        matches,
        index: 0,
        wordStart,
        insertedLen: 0,
        inserted: "",
        hasAt,
        isStart,
        basePartial: partial,
      };
      this.applyTabMatch(input, wordStart, after, this._tabCycle);
    });
  }

  // Write the current cycle match into the input and advance the caret.
  applyTabMatch(input, wordStart, after, cycle) {
    const nick = cycle.matches[cycle.index];
    // freeq-app style: keep a typed "@", use "nick: " only at line start.
    const prefix = cycle.hasAt ? "@" : "";
    const suffix = cycle.isStart ? ": " : " ";
    const replacement = prefix + nick + suffix;

    // Drop any leftover tail of the previous longer match when cycling.
    // `after` is whatever sat after the caret; if the caret was mid-token
    // from a prior insert, strip the remainder of that insert first.
    let rest = after;
    if (cycle.insertedLen > 0) {
      const already =
        (input.selectionStart ?? wordStart) - wordStart;
      const leftover = cycle.insertedLen - already;
      if (leftover > 0) rest = rest.slice(leftover);
    }

    input.value =
      input.value.substring(0, wordStart) + replacement + rest;
    cycle.insertedLen = replacement.length;
    cycle.inserted = replacement;
    const newCursor = wordStart + replacement.length;
    input.setSelectionRange(newCursor, newCursor);
  }

  getChannelNicks() {
    const panel = document.getElementById("member-panel");
    if (!panel) return [];
    // Prefer live member panel; fall back to distinct nicks seen in history.
    const fromPanel = Array.from(panel.querySelectorAll(".member .nick"))
      .map((el) => el.textContent.trim())
      .filter(Boolean);
    if (fromPanel.length) return fromPanel;

    const seen = new Set();
    const fromMsgs = [];
    document.querySelectorAll("#messages .msg[data-nick]").forEach((el) => {
      const n = (el.dataset.nick || "").trim();
      if (!n || seen.has(n.toLowerCase())) return;
      seen.add(n.toLowerCase());
      fromMsgs.push(n);
    });
    return fromMsgs;
  }

  // ── Direct Messages (E2EE) ──────────────────────────────────────────

  /**
   * Generate identity keys and publish the pre-key bundle.
   *
   * No /api/irc_status polling — that spammed the network when SASL stalled
   * (and previously re-spawned a dead upstream on every poll). Instead POST
   * once; the BFF waits up to ~15s for API-BEARER (with throttled re-spawn),
   * then one sparse retry if needed.
   */
  async ensureE2ee(did) {
    // Dedupe concurrent calls (Stimulus reconnect / Turbo can re-enter).
    if (this._e2eePromise) return this._e2eePromise;
    this._e2eePromise = this._ensureE2eeOnce(did).finally(() => {
      // Keep the settled promise so Turbo/Stimulus re-connect does not
      // re-fire a failed upload loop for the whole page lifetime.
      // Cleared only on full page navigation (new controller instance).
    });
    return this._e2eePromise;
  }

  async _ensureE2eeOnce(did) {
    const origin = dm.getServerOrigin();
    // Server-side upload_keys waits for SASL bearer (~15s). Sparse retry only.
    const delays = [0, 3000];
    for (let i = 0; i < delays.length; i++) {
      if (delays[i] > 0) {
        await new Promise((r) => setTimeout(r, delays[i]));
      }
      const uploaded = await dm.initE2ee(did, origin);
      if (uploaded) {
        console.log("[dm] E2EE pre-key published for", did);
        return;
      }
    }
    console.warn(
      "[dm] E2EE pre-key not published — IRC SASL may have failed or upstream is down. " +
        "Check that freeq-server is reachable (FREEQ_UPSTREAM), then sign out and sign in again."
    );
  }

  setupDm() {
    // Initialize E2EE when authenticated (DID available on the page).
    // Pre-key upload needs the BFF to hold an IRC API-BEARER (after SASL).
    const did = this.element.dataset.authDid;
    if (did) {
      this.ensureE2ee(did);
    }

    // Render the DM list in the sidebar.
    this.renderDmList();

    // Expose DM helpers globally for onclick handlers.
    window.openDm = (nick) => {
      dm.addDm(nick);
      window.location.href = `/chat/dm/${encodeURIComponent(nick)}`;
    };

    window.removeDm = (nick) => {
      dm.removeDm(nick);
      this.renderDmList();
      if (window.location.pathname === `/chat/dm/${encodeURIComponent(nick)}`) {
        window.location.href = "/chat";
      }
    };

    // DM send: encrypt in the browser, then POST to /api/dm/send.
    // We bypass the StimulusReflex form handler entirely for DMs —
    // the server only relays ciphertext.
    const form = document.getElementById("send-form");
    if (form && form.dataset.isDm === "true") {
      form.addEventListener("submit", async (e) => {
        e.preventDefault();
        e.stopPropagation();

        const input = document.getElementById("message-input");
        if (!input) return;
        const plaintext = input.value.trim();
        if (!plaintext) return;

        // Slash commands pass through to the reflex (e.g. /nick, /whois)
        if (plaintext.startsWith("/")) {
          input.dataset.skipDm = "true";
          form.requestSubmit();
          return;
        }

        const targetNick = form.dataset.channel;
        const remoteDid = await dm.nickToDidAsync(targetNick);
        if (!remoteDid) {
          const banner = document.getElementById("reply-banner");
          if (banner) {
            banner.innerHTML =
              '<span class="reply-banner-label" style="color:var(--nick-6)">Cannot encrypt — unknown recipient identity. Ask them to send a message first, or verify they are authenticated.</span>';
          }
          return;
        }

        const encResult = await dm.encryptDm(remoteDid, plaintext, dm.getServerOrigin());
        if (!encResult.ok) {
          const banner = document.getElementById("reply-banner");
          if (banner) {
            banner.innerHTML =
              '<span class="reply-banner-label" style="color:var(--nick-6)">' +
              escapeHtml(encResult.message || "Encryption failed") +
              "</span>";
          }
          return;
        }

        // Own echoes can't be Double-Ratchet-decrypted; stash plaintext.
        dm.cacheEcho(encResult.ok, plaintext);

        try {
          const resp = await fetch("/api/dm/send", {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
            },
            body: JSON.stringify({ nick: targetNick, msg: encResult.ok }),
          });
          if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        } catch (err) {
          const banner = document.getElementById("reply-banner");
          if (banner) {
            banner.innerHTML =
              '<span class="reply-banner-label" style="color:var(--nick-6)">Send failed: ' + escapeHtml(err.message) + '</span>';
          }
          return;
        }

        // Clear the input on success. The server will echo the PRIVMSG
        // back via CableReady, and decryptDmRows() will restore plaintext.
        input.value = "";
        const banner = document.getElementById("reply-banner");
        if (banner) banner.innerHTML = "";
      }, true);
    }

    // Decrypt any ENC3 rows already in the pane (CHATHISTORY / page load).
    // E2EE init is async — retry a few times until keys/sessions are ready.
    this.scheduleDecryptPass();

    // After a DM message is sent, clear the encrypted flag and restore
    // the input for the next message.
    const input = document.getElementById("message-input");
    if (input) {
      const observer = new MutationObserver(() => {
        if (input.value === "" && input.dataset.encrypted === "true") {
          delete input.dataset.encrypted;
          delete input.dataset.plaintext;
        }
      });
      observer.observe(input, { attributes: true, attributeFilter: ["value"] });
    }
  }

  // Render the DM section in the sidebar.
  renderDmList() {
    const list = document.getElementById("dm-list");
    if (!list) return;
    const dms = dm.loadDmList();
    const currentPath = window.location.pathname;
    list.innerHTML = dms
      .map((nick) => {
        const isActive = currentPath === `/chat/dm/${encodeURIComponent(nick)}`;
        const safe = escapeHtml(nick);
        return `<li class="sidebar-channel${isActive ? " active" : ""}" id="dm-${safe}">
          <a href="/chat/dm/${encodeURIComponent(nick)}" class="sidebar-channel-link">💬 ${safe}</a>
          <button type="button" class="sidebar-channel-part" title="Close DM"
                  data-nick="${safe}"
                  onclick="window.removeDm('${safe}')">×</button>
        </li>`;
      })
      .join("");
  }

  /** Retry decrypt while E2EE init / CHATHISTORY rows are still settling. */
  scheduleDecryptPass() {
    const delays = [0, 400, 1200, 3000];
    delays.forEach((ms) => {
      setTimeout(() => this.decryptDmRows(), ms);
    });
  }

  /**
   * Decrypt any ENC3: messages in the message pane.
   * - Outbound (our nick): use send-time echo cache (can't ratchet-decrypt own).
   * - Inbound: Double Ratchet with the partner DID.
   */
  async decryptDmRows() {
    const form = document.getElementById("send-form");
    const isDm = form?.dataset.isDm === "true";
    if (!isDm) return;

    const partnerNick = form.dataset.channel || this.bare;
    const ownNick = (this.element.dataset.authNick || "").trim();
    const ownHandle = (this.element.dataset.authHandle || "").trim();
    const ownDid = this.element.dataset.authDid || "";

    const rows = document.querySelectorAll("#messages .msg");
    for (const row of rows) {
      const wire = row.dataset.text || "";
      if (!wire || !dm.isEncryptedDm(wire)) continue;
      if (row.dataset.decrypted === "true") continue;

      const fromNick = (row.dataset.nick || "").trim();
      const fromDid = row.dataset.account || row.dataset.did || "";

      // 1) Own echo — restore from cache.
      const cached = dm.getEcho(wire);
      if (cached != null) {
        this.applyDecryptedRow(row, cached);
        continue;
      }

      // 2) Own row — DR cannot decrypt our send chain. Prefer echo cache
      //    (now persisted across refresh). Fall back to a muted placeholder.
      const fromLower = fromNick.toLowerCase();
      const isSelf =
        (ownDid && fromDid && fromDid === ownDid) ||
        (ownNick && fromLower === ownNick.toLowerCase()) ||
        (ownHandle && fromLower === ownHandle.toLowerCase());
      if (isSelf) {
        this.applyDecryptedRow(row, "[encrypted message — sent by you]", {
          placeholder: true,
        });
        continue;
      }

      // 3) Partner message — decrypt with session for their DID.
      //    Process rows in DOM order so the ratchet advances correctly on
      //    CHATHISTORY replay after refresh.
      const remoteDid =
        fromDid && fromDid.startsWith("did:")
          ? fromDid
          : await dm.nickToDidAsync(fromNick || partnerNick);
      if (!remoteDid) {
        this.applyDecryptedRow(row, "[encrypted DM — unknown sender identity]", {
          placeholder: true,
        });
        continue;
      }

      const plaintext = await dm.decryptDm(remoteDid, wire, dm.getServerOrigin());
      if (plaintext) {
        this.applyDecryptedRow(row, plaintext);
      } else {
        // Soft placeholder; leave decryptable so a later pass can retry
        // after E2EE init / session re-establish.
        this.applyDecryptedRow(
          row,
          "[could not decrypt]",
          { placeholder: true, sticky: false },
        );
      }
    }
  }

  applyDecryptedRow(row, plaintext, { placeholder = false, sticky = true } = {}) {
    if (!placeholder) {
      row.dataset.text = plaintext;
    }
    if (sticky) row.dataset.decrypted = "true";
    row.setAttribute("data-encrypted", "true");
    const body = row.querySelector(".body");
    if (!body) return;

    const nickEl = body.querySelector(".nick");
    const reactions = body.querySelector(".reactions");
    const replyBadge = body.querySelector(".reply-badge");
    const btns = body.querySelectorAll("button");
    body.innerHTML = "";
    delete row.dataset.embedsUrl;
    if (replyBadge) body.appendChild(replyBadge);
    if (nickEl) body.appendChild(nickEl);
    body.appendChild(document.createTextNode(" "));
    const textSpan = document.createElement("span");
    textSpan.textContent = plaintext;
    if (placeholder) textSpan.style.color = "var(--muted)";
    body.appendChild(textSpan);
    if (reactions) body.appendChild(reactions);
    btns.forEach((b) => body.appendChild(b));
    // Decrypted plaintext may contain URLs — re-run embeds for this pane.
    if (!placeholder) this.hydrateLinkEmbeds();
  }
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
