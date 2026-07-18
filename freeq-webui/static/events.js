/**
 * freeq-webui SSE bridge.
 * Opens EventSource for the current channel and applies patches to the DOM.
 */
(function () {
  const root = document.getElementById("freeq-chat");
  if (!root) return;

  const channel = root.dataset.channel;
  if (!channel) return;
  // Prefer explicit handle for reaction "mine" highlighting.
  if (root.dataset.authHandle) {
    document.body.setAttribute("data-auth-handle", root.dataset.authHandle);
  }

  const channelKey = "#" + channel;
  const REACT_CACHE_KEY = "freeq-reactions-v1";

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
    console.log("[freeq] opening SSE for", channel, "membersEl:", !!membersEl);
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
      console.log("[freeq] members event:", ev.data.slice(0, 80));
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

    es.addEventListener("reaction", (ev) => {
      try {
        const d = JSON.parse(ev.data);
        window.updateReactionChipFromServer(d.msgid, d.emoji, d.nick, !!d.added);
      } catch (e) {
        console.error("reaction event", e);
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

  // Reactions — optimistic UI + live updates from SSE `reaction` events.
  // Also cached in localStorage so chips survive refresh when the upstream
  // has not (or not yet) persisted +freeq.at/reactions on history.
  window.myReactions = window.myReactions || {};

  function loadReactCache() {
    try {
      return JSON.parse(localStorage.getItem(REACT_CACHE_KEY) || "{}");
    } catch {
      return {};
    }
  }
  function saveReactCache(cache) {
    try {
      localStorage.setItem(REACT_CACHE_KEY, JSON.stringify(cache));
    } catch {
      /* quota */
    }
  }
  function cacheGet(mid, emoji) {
    const c = loadReactCache();
    const ch = c[channelKey] || {};
    const m = ch[mid] || {};
    return m[emoji] ? m[emoji].slice() : [];
  }
  function cacheSetNicks(mid, emoji, nicks) {
    const c = loadReactCache();
    if (!c[channelKey]) c[channelKey] = {};
    if (!c[channelKey][mid]) c[channelKey][mid] = {};
    if (!nicks || nicks.length === 0) {
      delete c[channelKey][mid][emoji];
      if (Object.keys(c[channelKey][mid]).length === 0) delete c[channelKey][mid];
    } else {
      c[channelKey][mid][emoji] = nicks;
    }
    saveReactCache(c);
  }
  function cacheApplyNick(mid, emoji, nick, added) {
    let nicks = cacheGet(mid, emoji).filter(function (n) {
      return n !== nick;
    });
    if (added) nicks.push(nick);
    cacheSetNicks(mid, emoji, nicks);
    return nicks;
  }

  /** Re-apply cached chips onto SSR history after DOM is ready. */
  function hydrateReactionsFromCache() {
    const c = loadReactCache();
    const ch = c[channelKey];
    if (!ch) return;
    Object.keys(ch).forEach(function (mid) {
      const emojis = ch[mid];
      Object.keys(emojis).forEach(function (emoji) {
        const nicks = emojis[emoji] || [];
        nicks.forEach(function (nick) {
          window.updateReactionChipFromServer(mid, emoji, nick, true);
        });
      });
    });
  }

  function ensureReactionsContainer(row) {
    let container = row.querySelector(".reactions");
    if (container) return container;
    const body = row.querySelector(".body") || row;
    container = document.createElement("span");
    container.className = "reactions";
    const mid = row.getAttribute("data-msgid") || "";
    if (mid) {
      const plus = document.createElement("button");
      plus.type = "button";
      plus.className = "react-btn";
      plus.title = "React";
      plus.textContent = "+";
      plus.onclick = function () {
        window.openReactPicker(mid);
      };
      container.appendChild(plus);
    }
    body.appendChild(container);
    return container;
  }

  function updateReactionChip(mid, emoji, mine) {
    mid = String(mid || "");
    emoji = String(emoji || "");
    if (!mid || !emoji) return;
    const row = document.querySelector(
      '.msg[data-msgid="' + mid.replace(/"/g, '\\"') + '"]'
    );
    if (!row) return;
    const container = ensureReactionsContainer(row);
    let chip = container.querySelector(
      '.reaction-chip[data-emoji="' + emoji.replace(/"/g, '\\"') + '"]'
    );
    const me =
      document.body.getAttribute("data-auth-handle") ||
      document.documentElement.getAttribute("data-auth-handle") ||
      "you";
    if (chip) {
      let title = (chip.getAttribute("title") || "")
        .split(", ")
        .filter(function (n) {
          return n && n !== me;
        });
      if (mine) title.push(me);
      else if (title.length === 0) {
        chip.remove();
        return;
      }
      chip.setAttribute("title", title.join(", "));
      chip.textContent = title.length <= 1 ? emoji : emoji + " " + title.length;
      chip.classList.toggle("mine", mine);
    } else if (mine) {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "reaction-chip mine";
      b.setAttribute("data-emoji", emoji);
      b.setAttribute("data-msgid", mid);
      b.setAttribute("title", me);
      b.textContent = emoji;
      b.onclick = function () {
        window.toggleReaction(mid, emoji);
      };
      const plus = container.querySelector(".react-btn");
      if (plus) container.insertBefore(b, plus);
      else container.appendChild(b);
    }
  }

  window.updateReactionChipFromServer = function (mid, emoji, nick, added) {
    mid = String(mid || "");
    emoji = String(emoji || "");
    nick = String(nick || "");
    if (!mid || !emoji || !nick) return;
    const nicks = cacheApplyNick(mid, emoji, nick, added);
    const row = document.querySelector(
      '.msg[data-msgid="' + mid.replace(/"/g, '\\"') + '"]'
    );
    if (!row) return;
    const container = ensureReactionsContainer(row);
    let chip = container.querySelector(
      '.reaction-chip[data-emoji="' + emoji.replace(/"/g, '\\"') + '"]'
    );
    if (nicks.length === 0) {
      if (chip) chip.remove();
      return;
    }
    const title = nicks.join(", ");
    if (chip) {
      chip.setAttribute("title", title);
      chip.textContent = nicks.length <= 1 ? emoji : emoji + " " + nicks.length;
    } else {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "reaction-chip";
      b.setAttribute("data-emoji", emoji);
      b.setAttribute("data-msgid", mid);
      b.setAttribute("title", title);
      b.textContent = nicks.length <= 1 ? emoji : emoji + " " + nicks.length;
      b.onclick = function () {
        window.toggleReaction(mid, emoji);
      };
      const plus = container.querySelector(".react-btn");
      if (plus) container.insertBefore(b, plus);
      else container.appendChild(b);
      chip = b;
    }
    // Track own reactions for toggle state when echo arrives.
    const me =
      document.body.getAttribute("data-auth-handle") ||
      document.documentElement.getAttribute("data-auth-handle") ||
      "";
    if (me && nick === me) {
      if (!window.myReactions[mid]) window.myReactions[mid] = {};
      if (added) window.myReactions[mid][emoji] = true;
      else delete window.myReactions[mid][emoji];
    }
    if (chip && me) {
      chip.classList.toggle("mine", nicks.indexOf(me) >= 0);
    }
  };

  window.isReacted = function (msgid, emoji) {
    return !!(window.myReactions[msgid] && window.myReactions[msgid][emoji]);
  };

  window._reactInFlight = window._reactInFlight || {};

  window.toggleReaction = async function (msgid, emoji) {
    msgid = String(msgid || "");
    emoji = String(emoji || "");
    if (!msgid || !emoji) return;
    const key = msgid + "\u0000" + emoji;
    if (window._reactInFlight[key]) return;
    window._reactInFlight[key] = true;
    const mine = window.isReacted(msgid, emoji);
    const path = mine ? "unreact" : "react";
    if (!window.myReactions[msgid]) window.myReactions[msgid] = {};
    if (mine) delete window.myReactions[msgid][emoji];
    else window.myReactions[msgid][emoji] = true;
    try {
      const r = await fetch(
        "/chat/" + encodeURIComponent(channel) + "/" + path,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ msgid, emoji }),
          credentials: "same-origin",
        }
      );
      if (!r.ok) {
        if (mine) window.myReactions[msgid][emoji] = true;
        else delete window.myReactions[msgid][emoji];
        console.error(path + " failed", r.status);
      }
    } catch (e) {
      console.error("toggleReaction", e);
    } finally {
      delete window._reactInFlight[key];
    }
  };

  window.openReactPicker = function (msgid) {
    const picker = document.getElementById("react-picker");
    if (!picker) return;
    const emojis = ["👍", "❤️", "😂", "🎉", "🔥", "👀", "💯", "✨"];
    const mid = String(msgid || "").replace(/'/g, "\\'");
    picker.innerHTML = emojis
      .map(function (e) {
        const es = e.replace(/'/g, "\\'");
        return (
          "<button type=\"button\" onclick=\"window.toggleReaction('" +
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

  // After helpers exist and history SSR is in the DOM, re-apply cached chips.
  hydrateReactionsFromCache();

  // Policy modal — clean rules card (not raw NOTICE dump).
  window.showPolicy = async function (ch) {
    const modal = document.getElementById("policy-modal");
    const name = document.getElementById("policy-channel-name");
    const body = document.getElementById("policy-body");
    if (name) name.textContent = "#" + String(ch || "").replace(/^#/, "");
    if (body) {
      body.innerHTML =
        '<p class="text-zinc-500 text-sm animate-pulse">Loading policy…</p>';
    }
    modal?.classList.add("open");
    try {
      const r = await fetch("/api/policy/" + encodeURIComponent(ch));
      const html = await r.text();
      if (body) body.innerHTML = html;
    } catch {
      if (body) {
        body.innerHTML =
          '<p class="text-red-400 text-sm">Failed to load channel rules</p>';
      }
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
