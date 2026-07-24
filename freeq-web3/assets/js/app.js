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
const ChatScroll = {
  mounted() {
    // Double rAF so layout (including server-rendered preview cards) settles.
    requestAnimationFrame(() => {
      requestAnimationFrame(() => this.scrollToBottom());
    });
    this.handleEvent("scroll_bottom", () => this.scrollToBottom());
    this.handleEvent("focus_compose", () => this.focusCompose());
    this.handleEvent("scroll_to_message", ({ msgid }) =>
      this.scrollToMessage(msgid),
    );
    this.hydrateReplyBadges();
  },
  updated() {
    const el = this.el.querySelector("#messages");
    if (!el) return;
    const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 160;
    if (nearBottom) this.scrollToBottom();
    this.hydrateReplyBadges();
  },
  scrollToBottom() {
    const el = this.el.querySelector("#messages");
    if (el) el.scrollTop = el.scrollHeight;
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
