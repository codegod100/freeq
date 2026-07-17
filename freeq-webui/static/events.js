/**
 * freeq-webui SSE bridge.
 * Opens EventSource for the current channel and applies patches to the DOM.
 */
(function () {
  const root = document.getElementById("freeq-chat");
  if (!root) return;

  const channel = root.dataset.channel;
  if (!channel) return;

  const statusEl = document.getElementById("status");
  const messagesEl = document.getElementById("messages");
  const membersEl = document.getElementById("member-panel");
  const topicEl = document.getElementById("channel-topic");

  function setStatus(text, connected) {
    if (!statusEl) return;
    statusEl.classList.toggle("connected", !!connected);
    statusEl.innerHTML =
      '<span class="dot"></span> <span>' + text + "</span>";
  }

  function scrollMessages() {
    if (messagesEl) messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  function connect() {
    const es = new EventSource(
      "/chat/" + encodeURIComponent(channel) + "/events"
    );

    es.addEventListener("status", (ev) => {
      try {
        const data = JSON.parse(ev.data);
        if (data === "connected" || data.connected) {
          setStatus("connected", true);
        } else {
          setStatus(String(data), false);
        }
      } catch {
        setStatus(ev.data || "…", false);
      }
    });

    es.addEventListener("message", (ev) => {
      if (!messagesEl) return;
      messagesEl.insertAdjacentHTML("beforeend", ev.data);
      scrollMessages();
    });

    es.addEventListener("members", (ev) => {
      if (membersEl) membersEl.innerHTML = ev.data;
    });

    es.addEventListener("topic", (ev) => {
      if (!topicEl) return;
      try {
        topicEl.textContent = JSON.parse(ev.data);
      } catch {
        topicEl.textContent = ev.data;
      }
    });

    es.onerror = () => {
      setStatus("reconnecting…", false);
      es.close();
      setTimeout(connect, 1500);
    };

    setStatus("connecting…", false);
  }

  connect();

  // Mobile drawers
  window.toggleSidebar = function () {
    document.getElementById("sidebar")?.classList.toggle("open");
    document.getElementById("mobile-backdrop")?.classList.toggle("open");
  };
  window.toggleMembers = function () {
    document.getElementById("member-panel")?.classList.toggle("open");
    document.getElementById("mobile-backdrop")?.classList.toggle("open");
  };
  window.closeDrawers = function () {
    document.getElementById("sidebar")?.classList.remove("open");
    document.getElementById("member-panel")?.classList.remove("open");
    document.getElementById("mobile-backdrop")?.classList.remove("open");
  };

  // Compose: POST JSON without navigation
  const form = document.getElementById("send-form");
  if (form) {
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const input = form.querySelector('input[name="msg"]');
      const msg = input?.value?.trim();
      if (!msg) return;
      input.value = "";
      try {
        await fetch("/chat/" + encodeURIComponent(channel) + "/send", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ msg }),
        });
      } catch (err) {
        console.error("send failed", err);
      }
      input?.focus();
    });
  }

  // Join form
  const joinForm = document.getElementById("join-form");
  if (joinForm) {
    joinForm.addEventListener("submit", async (e) => {
      e.preventDefault();
      const input = joinForm.querySelector('input[name="channel"]');
      let ch = input?.value?.trim();
      if (!ch) return;
      if (!ch.startsWith("#")) ch = "#" + ch;
      try {
        await fetch("/chat/" + encodeURIComponent(ch.replace(/^#/, "")) + "/join", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ channel: ch }),
        });
        window.location.href = "/chat/" + encodeURIComponent(ch.replace(/^#/, ""));
      } catch (err) {
        console.error("join failed", err);
      }
    });
  }

  // Part button
  document.getElementById("part-btn")?.addEventListener("click", async () => {
    await fetch("/chat/" + encodeURIComponent(channel) + "/part", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    window.location.href = "/chat";
  });

  // Reactions
  window.myReactions = window.myReactions || {};
  window.isReacted = function (msgid, emoji) {
    return !!(window.myReactions[msgid] && window.myReactions[msgid][emoji]);
  };
  window.toggleReaction = async function (msgid, emoji) {
    const mine = window.isReacted(msgid, emoji);
    const path = mine ? "unreact" : "react";
    if (!window.myReactions[msgid]) window.myReactions[msgid] = {};
    if (mine) delete window.myReactions[msgid][emoji];
    else window.myReactions[msgid][emoji] = true;
    await fetch("/chat/" + encodeURIComponent(channel) + "/" + path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ msgid, emoji }),
    });
  };
  window.openReactPicker = function (msgid) {
    const picker = document.getElementById("react-picker");
    if (!picker) return;
    const emojis = ["👍", "❤️", "😂", "🎉", "🔥", "👀", "💯", "✨"];
    picker.innerHTML = emojis
      .map(
        (e) =>
          `<button type="button" onclick="window.toggleReaction('${msgid}','${e}');document.getElementById('react-picker').classList.remove('open')">${e}</button>`
      )
      .join("");
    picker.classList.add("open");
  };

  // Policy modal
  window.showPolicy = async function (ch) {
    const modal = document.getElementById("policy-modal");
    const name = document.getElementById("policy-channel-name");
    const body = document.getElementById("policy-body");
    if (name) name.textContent = "#" + ch;
    if (body) body.innerHTML = '<p class="text-zinc-400">Loading…</p>';
    modal?.classList.add("open");
    try {
      const r = await fetch("/api/policy/" + encodeURIComponent(ch));
      const t = await r.text();
      if (body) body.innerHTML = "<pre class='text-xs whitespace-pre-wrap'>" + t + "</pre>";
    } catch {
      if (body) body.innerHTML = '<p class="text-red-400">Failed to load policy</p>';
    }
  };
  window.closePolicy = function () {
    document.getElementById("policy-modal")?.classList.remove("open");
  };

  // Sidebar collapse toggles
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
})();
