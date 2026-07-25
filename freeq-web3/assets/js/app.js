// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/freeq_web3";
import topbar from "../vendor/topbar";
import AvCall from "./av_call";
import TabComplete from "./tab_complete";

// Link previews are rendered server-side with locally cached images
// (`/preview-cache/:id`). No client-side OG/image fetch on page load.

/**
 * Keep the chat shell sized to the *visual* viewport so mobile soft keyboards
 * do not cover #send-bar. iOS leaves layout viewport at full height; only
 * visualViewport shrinks. Mirrors freeq-app App.tsx keyboard handling.
 */
function syncVisualViewport() {
  const vv = window.visualViewport;
  if (!vv) {
    document.documentElement.style.setProperty(
      "--app-height",
      `${window.innerHeight}px`,
    );
    document.documentElement.style.setProperty("--app-offset-top", "0px");
    return;
  }
  // Height of the visible area; offsetTop shifts when the browser pans to the
  // focused input under the keyboard.
  document.documentElement.style.setProperty("--app-height", `${vv.height}px`);
  document.documentElement.style.setProperty(
    "--app-offset-top",
    `${vv.offsetTop}px`,
  );
}

function installVisualViewportSync() {
  if (window.__freeqVvInstalled) return;
  window.__freeqVvInstalled = true;
  syncVisualViewport();
  const vv = window.visualViewport;
  if (!vv) {
    window.addEventListener("resize", syncVisualViewport);
    return;
  }
  vv.addEventListener("resize", syncVisualViewport);
  vv.addEventListener("scroll", syncVisualViewport);
  window.addEventListener("orientationchange", () => {
    // iOS fires orientationchange before the new viewport settles.
    setTimeout(syncVisualViewport, 50);
    setTimeout(syncVisualViewport, 250);
  });
}
installVisualViewportSync();

const ChatScroll = {
  mounted() {
    this._channel = this.el.dataset.channel || "";
    // Double rAF so layout (including server-rendered preview cards) settles.
    this.scrollToBottomSoon();
    this.handleEvent("scroll_bottom", () => this.scrollToBottomSoon());
    this.handleEvent("focus_compose", () => this.focusCompose());
    this.handleEvent("scroll_to_message", ({ msgid }) =>
      this.scrollToMessage(msgid),
    );
    this.hydrateReplyBadges();
    this.localizeTimes();
    this.bindComposeKeyboard();
  },
  destroyed() {
    this.unbindComposeKeyboard();
  },
  updated() {
    const channel = this.el.dataset.channel || "";
    const channelChanged = channel !== this._channel;
    this._channel = channel;

    const el = this.el.querySelector("#messages");
    if (!el) return;

    // Live navigation between channels reuses this hook (no remount). Stream
    // reset leaves scroll at the top unless we force bottom.
    if (channelChanged) {
      this.scrollToBottomSoon();
    } else {
      const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 160;
      if (nearBottom) this.scrollToBottom();
    }
    this.hydrateReplyBadges();
    this.localizeTimes();
  },
  bindComposeKeyboard() {
    const input = this.el.querySelector("#message-input");
    if (!input) return;
    this._onComposeFocus = () => {
      // Re-measure after keyboard animation starts/finishes.
      syncVisualViewport();
      setTimeout(() => {
        syncVisualViewport();
        this.scrollToBottom();
        // Keep the focused field in the visual viewport (iOS pan fallback).
        input.scrollIntoView({ block: "nearest", inline: "nearest" });
      }, 50);
      setTimeout(() => {
        syncVisualViewport();
        this.scrollToBottom();
      }, 300);
    };
    this._onComposeBlur = () => {
      setTimeout(syncVisualViewport, 50);
      setTimeout(syncVisualViewport, 300);
    };
    input.addEventListener("focus", this._onComposeFocus);
    input.addEventListener("blur", this._onComposeBlur);
  },
  unbindComposeKeyboard() {
    const input = this.el.querySelector("#message-input");
    if (!input) return;
    if (this._onComposeFocus)
      input.removeEventListener("focus", this._onComposeFocus);
    if (this._onComposeBlur)
      input.removeEventListener("blur", this._onComposeBlur);
  },
  /**
   * Rewrite .ts[data-ts] into the browser's local timezone and rebuild
   * day separators on local calendar boundaries (web2 parity).
   * Server still emits UTC clocks as a no-JS fallback.
   */
  localizeTimes() {
    const root = this.el.querySelector("#messages") || this.el;
    if (!root) return;

    root.querySelectorAll(".ts[data-ts]").forEach((el) => {
      const sec = parseInt(el.dataset.ts, 10);
      if (!Number.isFinite(sec)) return;
      const d = new Date(sec * 1000);
      // NBSP so "4 PM" does not wrap between the time and meridiem.
      el.textContent = d
        .toLocaleTimeString(undefined, {
          hour: "numeric",
          minute: "2-digit",
          hour12: true,
        })
        .replace(/\s+/g, "\u00A0");
    });

    this.rebuildDateSeparators(root);
  },
  localDayKey(d) {
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${day}`;
  },
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
  },
  /**
   * Insert .date-sep rows between message stream items when the local
   * calendar day changes. Pure DOM (not LiveView stream items) — rebuilt
   * after every patch so stream morphdom can't leave stale separators.
   */
  rebuildDateSeparators(root) {
    root.querySelectorAll(".date-sep").forEach((el) => el.remove());

    let lastDay = null;
    // Only real message rows (have a clock). Skip join/part if they lack .ts
    // — our rows always include .ts when time is present.
    const children = Array.from(root.children);
    for (const node of children) {
      if (node.classList?.contains("date-sep")) continue;
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
  },
  scrollToBottom() {
    const el = this.el.querySelector("#messages");
    if (el) el.scrollTop = el.scrollHeight;
  },
  /** After stream reset / history paint, height may lag a frame or two. */
  scrollToBottomSoon() {
    this.scrollToBottom();
    requestAnimationFrame(() => {
      this.scrollToBottom();
      requestAnimationFrame(() => {
        this.scrollToBottom();
        // Preview images / fonts can still grow the pane slightly.
        clearTimeout(this._scrollTimer);
        this._scrollTimer = setTimeout(() => this.scrollToBottom(), 80);
      });
    });
  },
  focusCompose() {
    // After LV patches (reply/edit/send), restore keyboard focus to compose.
    requestAnimationFrame(() => {
      const input = this.el.querySelector("#message-input");
      if (input) input.focus();
    });
  },
  scrollToMessage(msgid) {
    const mid = String(msgid || "");
    if (!mid) return;
    const row = this.el.querySelector(
      `#messages [data-msgid="${CSS.escape(mid)}"]`,
    );
    if (!row) return;
    row.scrollIntoView({ behavior: "smooth", block: "center" });
    row.classList.add("highlight");
    setTimeout(() => row.classList.remove("highlight"), 1200);
  },
  // If a reply badge has no nick/text (parent not in server lookup), fill
  // from a parent row still present in the DOM.
  hydrateReplyBadges() {
    this.el.querySelectorAll(".reply-badge[data-reply-to]").forEach((badge) => {
      const mid = badge.getAttribute("data-reply-to");
      if (!mid) return;
      const nickEl = badge.querySelector(".reply-nick");
      const textEl = badge.querySelector(".reply-text");
      const needsNick =
        !nickEl || !nickEl.textContent || nickEl.textContent === "message";
      const needsText = !textEl || !textEl.textContent;
      if (!needsNick && !needsText) return;

      const parent = this.el.querySelector(
        `#messages [data-msgid="${CSS.escape(mid)}"]`,
      );
      if (!parent) return;
      if (needsNick && nickEl && parent.dataset.nick) {
        nickEl.textContent = parent.dataset.nick;
      }
      if (parent.dataset.text) {
        const t = parent.dataset.text.replace(/\s+/g, " ");
        const snippet = t.length > 80 ? t.slice(0, 80) + "…" : t;
        if (textEl) {
          textEl.textContent = snippet;
        } else if (needsText) {
          const span = document.createElement("span");
          span.className = "reply-text";
          span.textContent = snippet;
          badge.appendChild(span);
        }
      }
    });
  },
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { ...colocatedHooks, ChatScroll, AvCall, TabComplete },
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();

      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (_e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );

      window.liveReloader = reloader;
    },
  );
}
