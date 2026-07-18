/**
 * freeq-webui SSE bridge — one EventSource per session.
 *
 * Opens a single SSE connection to /events that survives channel switches.
 * Channel navigation is done client-side via history.pushState + fetch,
 * avoiding full page reloads and duplicate SSE connections.
 */
(function () {
  const root = document.getElementById("freeq-chat");
  if (!root) return;

  // ── State ────────────────────────────────────────────────────────────
  let currentChannel = root.dataset.channel || "";
  if (currentChannel && !currentChannel.startsWith("#")) {
    currentChannel = "#" + currentChannel;
  }

  // Prefer explicit handle for reaction "mine" highlighting.
  if (root.dataset.authHandle) {
    document.body.setAttribute("data-auth-handle", root.dataset.authHandle);
  }

  const channelKey = currentChannel; // for reaction cache key
  const REACT_CACHE_KEY = "freeq-reactions-v1";

  // ── DOM refs ─────────────────────────────────────────────────────────
  const statusEl = document.getElementById("status");
  const messagesEl = document.getElementById("messages");
  const membersEl = document.getElementById("member-panel");
  const topicEl = document.getElementById("channel-topic");
  const channelLabelEl = document.querySelector('nav .text-\\[\\#7ab7ff\\]');

  function setStatus(text, connected) {
    if (!statusEl) return;
    statusEl.classList.toggle("connected", !!connected);
    statusEl.innerHTML =
      '<span class="dot"></span> <span>' + text + "</span>";
  }

  function scrollMessages() {
    if (messagesEl) messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  // ── Channel switching (client-side, no page reload) ──────────────────

  function updateSidebarActive(channelBare) {
    // Highlight the active channel in the sidebar.
    const links = document.querySelectorAll("#sidebar a");
    links.forEach(function (a) {
      const href = a.getAttribute("href") || "";
      const bare = href.replace(/^\/chat\//, "");
      const isActive = bare === channelBare;
      a.className = isActive
        ? "block rounded px-2 py-1 bg-[#7ab7ff] text-[#0e1116] font-medium"
        : "block rounded px-2 py-1 text-zinc-300 hover:bg-[#151a22]";
      a.style.cssText = "flex:1;min-width:0;overflow-wrap:anywhere";
    });
  }

  window.switchChannel = async function (channelBare) {
    if (!channelBare) return;
    const newChannel = channelBare.startsWith("#")
      ? channelBare
      : "#" + channelBare;

    // Already viewing this channel?
    if (
      newChannel.toLowerCase() === currentChannel.toLowerCase() &&
      messagesEl &&
      messagesEl.children.length > 0
    ) {
      return;
    }

    // Update URL without page reload.
    history.pushState({ channel: channelBare }, "", "/chat/" + channelBare);

    await loadChannel(channelBare);
  };

  async function loadChannel(channelBare) {
    const newChannel = channelBare.startsWith("#")
      ? channelBare
      : "#" + channelBare;
    currentChannel = newChannel;
    root.dataset.channel = channelBare;

    // Update nav label.
    if (channelLabelEl) channelLabelEl.textContent = newChannel;

    // Update sidebar highlight.
    updateSidebarActive(channelBare);

    // Update compose placeholder.
    const input = document.querySelector('#send-form input[name="msg"]');
    if (input) input.placeholder = "Send to " + newChannel + "…";

    // Clear and show loading state.
    if (messagesEl) messagesEl.innerHTML = "";
    if (membersEl) membersEl.innerHTML = "";
    setStatus("loading…", false);

    // Close mobile drawers.
    closeDrawers();

    try {
      const r = await fetch("/api/channel/" + encodeURIComponent(channelBare));
      if (!r.ok) throw new Error("HTTP " + r.status);
      const data = await r.json();

      if (messagesEl) {
        messagesEl.innerHTML = data.messages_html || "";
        scrollMessages();
      }
      if (membersEl) membersEl.innerHTML = data.members_html || "";
      if (topicEl) topicEl.textContent = data.topic || "";

      // Re-apply cached reactions for this channel.
      hydrateReactionsFromCache();
    } catch (e) {
      console.error("[freeq] channel load failed", e);
      if (messagesEl) {
        messagesEl.innerHTML =
          '<div class="notice"><span class="body">Failed to load channel. Try refreshing.</span></div>';
      }
    }

    // Refresh sidebar to reflect joined state.
    refreshSidebar(channelBare);
  }

  async function refreshSidebar(channelBare) {
    try {
      const r = await fetch("/api/sidebar/" + encodeURIComponent(channelBare));
      if (!r.ok) return;
      const data = await r.json();
      const myList = document.getElementById("my-channels");
      const allList = document.getElementById("all-channels");
      if (myList) myList.innerHTML = data.my_channels_html || "";
      if (allList) allList.innerHTML = data.all_channels_html || "";
    } catch (e) {
      console.error("[freeq] sidebar refresh failed", e);
    }
  }

  // Handle back/forward button.
  window.addEventListener("popstate", function (ev) {
    const path = window.location.pathname;
    const match = path.match(/^\/chat\/(.+)$/);
    if (match) {
      loadChannel(match[1]);
    }
  });

  // ── SSE connection (one per session) ─────────────────────────────────

  let es = null;

  function connect() {
    console.log("[freeq] opening session SSE");
    es = new EventSource("/events");

    es.addEventListener("status", function (ev) {
      try {
        const data = JSON.parse(ev.data);
        if (data.status === "connected") {
          setStatus("connected", true);
        } else {
          setStatus(String(data.status || "…"), false);
        }
      } catch {
        setStatus(ev.data || "…", false);
      }
    });

    es.addEventListener("message", function (ev) {
      if (!messagesEl) return;
      try {
        const data = JSON.parse(ev.data);
        // Filter: only show if channel matches or is session-wide.
        if (data.channel) {
          if (
            !data.channel.toLowerCase().startsWith("#") ||
            data.channel.toLowerCase() !== currentChannel.toLowerCase()
          ) {
            return;
          }
        }
        messagesEl.insertAdjacentHTML("beforeend", data.html);
        scrollMessages();
      } catch (e) {
        console.error("[freeq] message event parse error", e);
      }
    });

    es.addEventListener("members", function (ev) {
      try {
        const data = JSON.parse(ev.data);
        if (!data.channel) return;
        if (data.channel.toLowerCase() !== currentChannel.toLowerCase()) return;
        if (membersEl) membersEl.innerHTML = data.html;
      } catch (e) {
        console.error("[freeq] members event parse error", e);
      }
    });

    es.addEventListener("topic", function (ev) {
      try {
        const data = JSON.parse(ev.data);
        if (!data.channel) return;
        if (data.channel.toLowerCase() !== currentChannel.toLowerCase()) return;
        if (topicEl) topicEl.textContent = data.topic || "";
      } catch (e) {
        console.error("[freeq] topic event parse error", e);
      }
    });

    es.addEventListener("reaction", function (ev) {
      try {
        const data = JSON.parse(ev.data);
        if (data.channel && data.channel.toLowerCase() !== currentChannel.toLowerCase()) return;
        window.updateReactionChipFromServer(
          data.msgid,
          data.emoji,
          data.nick,
          !!data.added
        );
      } catch (e) {
        console.error("[freeq] reaction event", e);
      }
    });

    es.onerror = function () {
      setStatus("reconnecting…", false);
      if (es) es.close();
      es = null;
      setTimeout(connect, 1500);
    };

    setStatus("connecting…", false);
  }

  connect();

  // ── Mobile drawers ──────────────────────────────────────────────────
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

  // ── Compose ─────────────────────────────────────────────────────────
  const form = document.getElementById("send-form");
  if (form) {
    form.addEventListener("submit", async function (e) {
      e.preventDefault();
      const input = form.querySelector('input[name="msg"]');
      const msg = input?.value?.trim();
      if (!msg) return;
      input.value = "";
      try {
        await fetch(
          "/chat/" + encodeURIComponent(currentChannel.replace(/^#/, "")) + "/send",
          {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ msg }),
          }
        );
      } catch (err) {
        console.error("send failed", err);
      }
      input?.focus();
    });
  }

  // ── Join form ───────────────────────────────────────────────────────
  const joinForm = document.getElementById("join-form");
  if (joinForm) {
    joinForm.addEventListener("submit", async function (e) {
      e.preventDefault();
      const input = joinForm.querySelector('input[name="channel"]');
      let ch = input?.value?.trim();
      if (!ch) return;
      if (!ch.startsWith("#")) ch = "#" + ch;
      input.value = "";
      const bare = ch.replace(/^#/, "");
      try {
        await fetch("/chat/" + encodeURIComponent(bare) + "/join", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ channel: ch }),
        });
        // Switch to the new channel client-side.
        await window.switchChannel(bare);
      } catch (err) {
        console.error("join failed", err);
      }
    });
  }

  // ── Part button ─────────────────────────────────────────────────────
  document.getElementById("part-btn")?.addEventListener("click", async function () {
    await fetch(
      "/chat/" + encodeURIComponent(currentChannel.replace(/^#/, "")) + "/part",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      }
    );
    // Navigate to channel list page (full load — no chat to show).
    window.location.href = "/chat";
  });

  // ── Reactions ───────────────────────────────────────────────────────
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
    const ch = c["#" + currentChannel.replace(/^#/, "")] || {};
    const m = ch[mid] || {};
    return m[emoji] ? m[emoji].slice() : [];
  }
  function cacheSetNicks(mid, emoji, nicks) {
    const c = loadReactCache();
    const key = "#" + currentChannel.replace(/^#/, "");
    if (!c[key]) c[key] = {};
    if (!c[key][mid]) c[key][mid] = {};
    if (!nicks || nicks.length === 0) {
      delete c[key][mid][emoji];
      if (Object.keys(c[key][mid]).length === 0) delete c[key][mid];
    } else {
      c[key][mid][emoji] = nicks;
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

  function hydrateReactionsFromCache() {
    const c = loadReactCache();
    const chKey = "#" + currentChannel.replace(/^#/, "");
    const ch = c[chKey];
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
        "/chat/" +
          encodeURIComponent(currentChannel.replace(/^#/, "")) +
          "/" +
          path,
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

  // Apply cached reactions after DOM is ready.
  hydrateReactionsFromCache();

  // ── Policy modal ────────────────────────────────────────────────────
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

  // ── Sidebar collapse toggles ─────────────────────────────────────────
  document.querySelectorAll(".sidebar-toggle").forEach(function (el) {
    el.addEventListener("click", function () {
      const id = el.dataset.target;
      const list = id && document.getElementById(id);
      if (!list) return;
      const hidden = list.style.display === "none";
      list.style.display = hidden ? "" : "none";
      el.classList.toggle("collapsed", !hidden);
    });
  });
})();
