import { Controller } from "@hotwired/stimulus";
import consumer from "../channels/consumer";
import CableReady from "cable_ready";
import StimulusReflex from "stimulus_reflex";

// Client-side chat controller: ChatChannel live updates, reactions, replies.
export default class ChatController extends Controller {
  connect() {
    StimulusReflex.useReflex(this);
    this.setupChannel();
    this.setupReactions();
    this.setupReplies();
    this.setupSidebar();
    this.setupTabComplete();
    this.hydrateReplyBadges();
    this.scrollToBottom();

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
            this.scrollToBottom();
          }
        },
        connected: () => this.setStatus("connected", true),
        disconnected: () => this.setStatus("reconnecting…", false),
      }
    );
  }

  disconnect() {
    this.subscription?.unsubscribe();
    if (this._onReaction) {
      this.element.removeEventListener("freeq:reaction", this._onReaction);
    }
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
      // No optimistic update — wait for the server echo via freeq:reaction
      // event so the nick matches exactly and we don't double-count.
      const payload = new FormData();
      payload.append("msgid", msgid);
      payload.append("emoji", emoji);
      try {
        await fetch(`/chat/${encodeURIComponent(channel)}/${path}`, {
          method: "POST",
          headers: {
            "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')
              .content,
          },
          body: payload,
          credentials: "same-origin",
        });
      } catch (e) {
        console.error("toggleReaction", e);
      }
    };
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
    const me =
      document.body.getAttribute("data-auth-handle") ||
      this.element.dataset.authHandle ||
      "";
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
    let nicks = (chip.getAttribute("title") || "")
      .split(", ")
      .filter(Boolean)
      .filter((n) => n !== nick);
    if (added) nicks.push(nick);
    if (nicks.length === 0) {
      chip.remove();
      return;
    }
    chip.setAttribute("title", nicks.join(", "));
    chip.textContent = nicks.length <= 1 ? emoji : emoji + " " + nicks.length;
    if (me) chip.classList.toggle("mine", nicks.includes(me));
  }

  setupSidebar() {
    window.toggleSidebar = () => {
      document.getElementById("sidebar")?.classList.toggle("open");
    };
    window.toggleMembers = () => {
      document.getElementById("member-panel")?.classList.toggle("open");
    };
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
  }

  // ── Tab completion ───────────────────────────────────────────────────

  setupTabComplete() {
    const input = document.getElementById("message-input");
    if (!input) return;

    this._tabCycle = null; // { matches, index, start, end }

    input.addEventListener("keydown", (e) => {
      if (e.key !== "Tab") {
        this._tabCycle = null;
        return;
      }
      e.preventDefault();

      const pos = input.selectionStart;
      const before = input.value.substring(0, pos);
      const after = input.value.substring(pos);

      // Find the word boundary before the cursor.
      const m = before.match(/(\w[\w.\-]*)$/);
      if (!m) return;
      const wordStart = before.length - m[1].length;
      const partial = m[1].toLowerCase();

      // Get nicks from the member panel.
      const nicks = this.getChannelNicks();
      if (!nicks.length) return;

      // Filter or use cached cycle.
      if (!this._tabCycle || this._tabCycle.partial !== partial) {
        let matches;
        if (partial === "") {
          matches = nicks.slice();
        } else {
          matches = nicks.filter((n) => n.toLowerCase().startsWith(partial));
        }
        if (!matches.length) return;
        // Sort: ops first, then alphabetically — already sorted by the renderer.
        this._tabCycle = { matches, index: 0, partial, wordStart };
      } else {
        this._tabCycle.index =
          (this._tabCycle.index + 1) % this._tabCycle.matches.length;
      }

      const nick = this._tabCycle.matches[this._tabCycle.index];
      // If completing at the start of the line, append ": " for a mention.
      const isStart = wordStart === 0;
      const suffix = isStart ? ": " : "";
      const replacement = nick + suffix;

      input.value =
        input.value.substring(0, wordStart) + replacement + after;
      const newCursor = wordStart + replacement.length;
      input.setSelectionRange(newCursor, newCursor);
    });
  }

  getChannelNicks() {
    const panel = document.getElementById("member-panel");
    if (!panel) return [];
    return Array.from(panel.querySelectorAll(".member .nick"))
      .map((el) => el.textContent.trim())
      .filter(Boolean);
  }
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
