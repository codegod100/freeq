import { Controller } from "@hotwired/stimulus";
import consumer from "../channels/consumer";
import CableReady from "cable_ready";
import StimulusReflex from "stimulus_reflex";

// Client-side chat controller: subscribes to ChatChannel for live CableReady
// broadcasts, manages reaction picker + sidebar, and wires StimulusReflex.
export default class ChatController extends Controller {
  connect() {
    StimulusReflex.useReflex(this);
    this.setupChannel();
    this.setupReactions();
    this.setupSidebar();
    this.scrollToBottom();

    // Live reaction events from IrcBroadcaster.
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
            CableReady.perform(data.operations);
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
      const me =
        document.body.getAttribute("data-auth-handle") ||
        self.element.dataset.authHandle ||
        "you";
      // Optimistic chip update (server echo may re-apply the same chip).
      self.applyReaction(msgid, emoji, me, !mine);
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
}

