// IRC-style Tab nick completion for the channel compose box.
// Port of freeq-web2 chat_controller setupTabComplete / applyTabMatch.

function channelNicks() {
  const panel = document.getElementById("member-panel");
  if (panel) {
    const fromPanel = Array.from(panel.querySelectorAll(".member[data-nick], .member .nick"))
      .map((el) => (el.dataset.nick || el.textContent || "").trim())
      .filter(Boolean);
    // de-dupe case-insensitively, keep first casing
    if (fromPanel.length) {
      const seen = new Set();
      const out = [];
      for (const n of fromPanel) {
        const k = n.toLowerCase();
        if (seen.has(k)) continue;
        seen.add(k);
        out.push(n);
      }
      return out;
    }
  }

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

function applyTabMatch(input, wordStart, after, cycle) {
  const nick = cycle.matches[cycle.index];
  // freeq-app style: keep a typed "@", use "nick: " only at line start.
  const prefix = cycle.hasAt ? "@" : "";
  const suffix = cycle.isStart ? ": " : " ";
  const replacement = prefix + nick + suffix;

  let rest = after;
  if (cycle.insertedLen > 0) {
    const already = (input.selectionStart ?? wordStart) - wordStart;
    const leftover = cycle.insertedLen - already;
    if (leftover > 0) rest = rest.slice(leftover);
  }

  input.value = input.value.substring(0, wordStart) + replacement + rest;
  cycle.insertedLen = replacement.length;
  cycle.inserted = replacement;
  const newCursor = wordStart + replacement.length;
  input.setSelectionRange(newCursor, newCursor);
}

const TabComplete = {
  mounted() {
    this._tabCycle = null;
    this._onKeyDown = (e) => this.onKeyDown(e);
    this.el.addEventListener("keydown", this._onKeyDown);
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._onKeyDown);
    this._tabCycle = null;
  },

  onKeyDown(e) {
    const input = this.el;

    if (e.key !== "Tab") {
      // Any other key breaks the cycle (same as web2).
      if (this._tabCycle && e.key !== "Shift") this._tabCycle = null;
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
        this._tabCycle.index = (this._tabCycle.index + 1) % matches.length;
        applyTabMatch(input, wordStart, after, this._tabCycle);
        this.syncCompose(input.value);
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

    const nicks = channelNicks();
    if (!nicks.length) return;

    const matches =
      partial === ""
        ? nicks.slice()
        : nicks.filter((n) => n.toLowerCase().startsWith(partial));
    if (!matches.length) return;

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
    applyTabMatch(input, wordStart, after, this._tabCycle);
    this.syncCompose(input.value);
  },

  // Keep LiveView @compose in sync so LV patches don't wipe the completion.
  syncCompose(value) {
    this.pushEvent("compose_change", { msg: value });
  },
};

export default TabComplete;
