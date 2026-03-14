#!/usr/bin/env python3
"""
Phase 1: Known Actors — Step-by-Step Interactive Demo
======================================================
Each feature step waits for chadfowler.com to say "next" (or "n") before proceeding.
"""

import ssl, socket, time, base64, json, threading, sys, os

sys.stdout.reconfigure(line_buffering=True)

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

CHAN = "#chad-dev"
HOST = "irc.freeq.at"
PORT = 6697
OWNER = "chadfowler.com"

KEY_DIR = os.path.expanduser("~/.freeq/bots/scout-bot")


def _derive_did(pub_bytes):
    ALPHABET = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    mc = b"\xed\x01" + pub_bytes
    n = int.from_bytes(mc, "big")
    result = b""
    while n > 0:
        n, r = divmod(n, 58)
        result = ALPHABET[r : r + 1] + result
    return "did:key:z" + result.decode()


def generate_did_key():
    key_path = os.path.join(KEY_DIR, "key.ed25519")
    if os.path.exists(key_path):
        seed = open(key_path, "rb").read()
        key = Ed25519PrivateKey.from_private_bytes(seed)
        pub = key.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw
        )
        return key, _derive_did(pub)

    seed = os.urandom(32)
    key = Ed25519PrivateKey.from_private_bytes(seed)
    pub = key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    did = _derive_did(pub)
    os.makedirs(KEY_DIR, exist_ok=True)
    with open(key_path, "wb") as f:
        f.write(seed)
    return key, did


class IRCBot:
    def __init__(self, nick, key=None, did=None):
        self.nick = nick
        self.key = key
        self.did = did
        self.sock = None
        self.lines = []
        self._reader = None

    def connect(self):
        ctx = ssl.create_default_context()
        raw = socket.socket()
        self.sock = ctx.wrap_socket(raw, server_hostname=HOST)
        self.sock.settimeout(2)
        self.sock.connect((HOST, PORT))
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    def _read_loop(self):
        buf = ""
        while True:
            try:
                data = self.sock.recv(4096).decode(errors="replace")
                if not data:
                    break
                buf += data
                while "\r\n" in buf:
                    line, buf = buf.split("\r\n", 1)
                    if line.startswith("PING"):
                        try:
                            self.sock.send(("PONG" + line[4:] + "\r\n").encode())
                        except:
                            pass
                    self.lines.append(line)
            except socket.timeout:
                continue
            except:
                break

    def send_raw(self, msg):
        self.sock.send((msg + "\r\n").encode())

    def wait_for(self, pattern, timeout=5):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for i, line in enumerate(self.lines):
                if pattern in line:
                    self.lines = self.lines[i + 1 :]
                    return line
            time.sleep(0.1)
        return None

    def drain(self, wait=0.3):
        time.sleep(wait)
        self.lines.clear()

    def say(self, target, text):
        self.send_raw(f"PRIVMSG {target} :{text}")
        time.sleep(0.4)

    def cmd(self, raw):
        self.send_raw(raw)
        time.sleep(0.3)

    def register(self):
        self.send_raw("CAP LS 302")
        self.send_raw(f"NICK {self.nick}")
        self.send_raw(f"USER {self.nick} 0 * :Phase 1 Demo Agent")
        time.sleep(1)

        if self.key:
            self.drain(0.5)
            self.send_raw("CAP REQ :sasl message-tags server-time echo-message")
            self.wait_for("ACK", 5)
            self.send_raw("AUTHENTICATE ATPROTO-CHALLENGE")

            challenge_line = self.wait_for("AUTHENTICATE", 5)
            if challenge_line:
                challenge_b64 = challenge_line.split(" ")[-1]
                if challenge_b64 and challenge_b64 != "+":
                    padded = challenge_b64 + "=" * (-len(challenge_b64) % 4)
                    try:
                        challenge_bytes = base64.urlsafe_b64decode(padded)
                    except Exception:
                        challenge_bytes = base64.b64decode(padded)

                    signature = self.key.sign(challenge_bytes)
                    sig_b64 = base64.urlsafe_b64encode(signature).rstrip(b"=").decode()
                    response_json = json.dumps({"did": self.did, "signature": sig_b64})
                    resp_b64 = base64.urlsafe_b64encode(response_json.encode()).rstrip(b"=").decode()
                    self.send_raw(f"AUTHENTICATE {resp_b64}")
                    self.wait_for("903", 5)

            self.send_raw("CAP END")
        else:
            self.send_raw("CAP END")

        self.wait_for("001", 10)
        self.drain()

    def wait_for_owner(self, timeout=300):
        """Wait for OWNER to say something in the channel. Returns the message text."""
        deadline = time.time() + timeout
        last_heartbeat = time.time()
        while time.time() < deadline:
            # Keep heartbeat alive
            if time.time() - last_heartbeat > 25:
                self.cmd("HEARTBEAT 60")
                last_heartbeat = time.time()
            for i, line in enumerate(self.lines):
                if f"PRIVMSG {CHAN}" in line and f":{OWNER}!" in line:
                    parts = line.split(f"PRIVMSG {CHAN} :", 1)
                    text = parts[1] if len(parts) > 1 else ""
                    self.lines = self.lines[i + 1 :]
                    return text
            time.sleep(0.2)
        return None

    def wait_for_continue(self):
        """Wait for owner to say 'next', 'n', 'continue', 'go', 'ok', etc."""
        self.say(CHAN, "")
        self.say(CHAN, "👉 Say "next" when you're ready to continue.")
        while True:
            msg = self.wait_for_owner(timeout=300)
            if msg is None:
                return False
            lower = msg.strip().lower()
            # Accept various continue signals
            if lower in ("next", "n", "go", "continue", "ok", "k", "yes", "y", "ready"):
                return True
            # Also accept if addressed to us
            for prefix in ("scout-bot:", "scout-bot,", "@scout-bot"):
                if lower.startswith(prefix):
                    rest = lower[len(prefix):].strip()
                    if rest in ("next", "n", "go", "continue", "ok", "k", "yes", "y", "ready"):
                        return True


# ═══════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════

print("Phase 1: Known Actors — Interactive Demo")
print("=" * 45)

key, did = generate_did_key()

# Kill any existing scout-bot by ghosting
NICK = "scout-bot"
bot = IRCBot(NICK, key, did)
bot.connect()
bot.register()

bot.cmd(f"JOIN {CHAN}")
bot.wait_for("366", 5)
bot.drain()

# ─── Intro ──────────────────────────────────────
bot.say(CHAN, "👋 Hey! I'm scout-bot — a demo agent for Phase 1: Known Actors.")
bot.say(CHAN, "I'll walk you through each feature one at a time.")
bot.say(CHAN, "After each feature, I'll wait for you to say "next" before continuing.")
bot.say(CHAN, "There are 7 features to demo. Let's start.")

if not bot.wait_for_continue():
    sys.exit(1)

# ─── Step 1: did:key SASL Authentication ────────
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Step 1 of 7: did:key SASL Authentication ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "Before I even joined this channel, I authenticated with the server using SASL.")
bot.say(CHAN, "The mechanism is called ATPROTO-CHALLENGE. Here's what happened:")
bot.say(CHAN, "")
bot.say(CHAN, "  1️⃣  I generated an ed25519 keypair in memory")
bot.say(CHAN, "  2️⃣  I derived a DID from the public key — no registry, no network call")
bot.say(CHAN, f"  3️⃣  My DID: {did}")
bot.say(CHAN, "  4️⃣  The server sent me a random challenge")
bot.say(CHAN, "  5️⃣  I signed the challenge with my private key")
bot.say(CHAN, "  6️⃣  The server verified the signature against the public key in the DID")
bot.say(CHAN, "")
bot.say(CHAN, "No Bluesky account. No PDS. No domain. Just math.")
bot.say(CHAN, "This is how bots get cryptographic identity with zero infrastructure.")

if not bot.wait_for_continue():
    sys.exit(1)

# ─── Step 2: Actor Class Registration ──────────
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Step 2 of 7: Actor Class Registration ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "Right now the server knows I'm authenticated, but it doesn't know I'm a bot.")
bot.say(CHAN, "Watch the member list — I'm about to register as an agent.")
time.sleep(2)

bot.cmd("AGENT REGISTER :class=agent")
time.sleep(1)

bot.say(CHAN, "✅ Sent: AGENT REGISTER :class=agent")
bot.say(CHAN, "")
bot.say(CHAN, "Check the member list now. You should see:")
bot.say(CHAN, "  • A 🤖 badge next to my name")
bot.say(CHAN, "  • I'm in a separate \"Agents\" section, below the humans")
bot.say(CHAN, "")
bot.say(CHAN, "A user on irssi or weechat sees nothing different — I'm just another nick.")
bot.say(CHAN, "But the web client knows I'm an agent and shows it visually.")

if not bot.wait_for_continue():
    sys.exit(1)

# ─── Step 3: Provenance Declaration ────────────
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Step 3 of 7: Provenance Declaration ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "Now I'll declare who created me and where my code lives.")
bot.say(CHAN, "This is machine-readable metadata stored on the server.")

provenance = {
    "actor_did": did,
    "origin_type": "external_import",
    "creator_did": "did:plc:4qsyxmnsblo4luuycm3572bq",
    "implementation_ref": "freeq/demo-phase1.py@HEAD",
    "source_repo": "https://github.com/chad/freeq",
    "authority_basis": "Operated by server administrator (chadfowler.com)",
    "revocation_authority": "did:plc:4qsyxmnsblo4luuycm3572bq",
}
prov_json = json.dumps(provenance)
prov_b64 = base64.urlsafe_b64encode(prov_json.encode()).rstrip(b"=").decode()
bot.cmd(f"PROVENANCE :{prov_b64}")
time.sleep(0.5)

bot.say(CHAN, "")
bot.say(CHAN, "✅ Provenance registered:")
bot.say(CHAN, f"   👤 Creator: chadfowler.com")
bot.say(CHAN, f"   📦 Source: https://github.com/chad/freeq")
bot.say(CHAN, f"   🔧 Code: demo-phase1.py")
bot.say(CHAN, f"   ⚖️  Revocation authority: chadfowler.com")
bot.say(CHAN, "")
bot.say(CHAN, "Anyone can verify this. Try clicking my name in the member list —")
bot.say(CHAN, "you should see an identity card with this provenance info.")

if not bot.wait_for_continue():
    sys.exit(1)

# ─── Step 4: Rich Presence ─────────────────────
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Step 4 of 7: Rich Agent Presence ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "Agents have structured presence — not just online/away, but 13 distinct states.")
bot.say(CHAN, "Watch my status change in real time. I'll cycle through several states:")
bot.say(CHAN, "")

states = [
    ("idle",       "💤", "Waiting for instructions"),
    ("active",     "⚡", "Processing request"),
    ("executing",  "🔨", "Running code analysis"),
    ("waiting_for_input", "⏳", "Need your approval"),
    ("blocked_on_permission", "🔒", "Waiting for channel op"),
    ("rate_limited", "🚦", "Backing off — too many API calls"),
    ("paused",     "⏸️", "Paused by governance action"),
    ("degraded",   "🟡", "Heartbeat late"),
]

for state, emoji, status in states:
    bot.cmd(f"PRESENCE :state={state};status={status}")
    bot.say(CHAN, f"   {emoji} {state}: {status}")
    time.sleep(1.5)

bot.cmd("PRESENCE :state=active;status=Running Phase 1 demo")
bot.say(CHAN, "")
bot.say(CHAN, "Each state transition is broadcast to everyone in the channel.")
bot.say(CHAN, "The full set: online, idle, active, executing, waiting_for_input,")
bot.say(CHAN, "blocked_on_permission, blocked_on_budget, degraded, paused,")
bot.say(CHAN, "sandboxed, rate_limited, revoked, offline.")

if not bot.wait_for_continue():
    sys.exit(1)

# ─── Step 5: Heartbeat ─────────────────────────
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Step 5 of 7: Signed Heartbeat with TTL ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "I send a HEARTBEAT command every 25 seconds with a 60-second TTL.")
bot.cmd("HEARTBEAT 60")
bot.say(CHAN, "✅ HEARTBEAT 60 sent just now.")
bot.say(CHAN, "")
bot.say(CHAN, "If I stop heartbeating, the server automatically detects it:")
bot.say(CHAN, "   • After 60s (1× TTL):  → degraded 🟡")
bot.say(CHAN, "   • After 120s (2× TTL): → offline ⚫")
bot.say(CHAN, "   • After 300s (5× TTL): → force disconnect")
bot.say(CHAN, "")
bot.say(CHAN, "No health check endpoints. No polling. The server watches the heartbeat")
bot.say(CHAN, "and transitions my presence state automatically.")

if not bot.wait_for_continue():
    sys.exit(1)

# ─── Step 6: REST Identity Card ────────────────
encoded_did = did.replace(":", "%3A")
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Step 6 of 7: Identity Card REST API ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "Everything about me is queryable via a REST endpoint:")
bot.say(CHAN, f"   https://irc.freeq.at/api/v1/actors/{encoded_did}")
bot.say(CHAN, "")
bot.say(CHAN, "That returns JSON with:")
bot.say(CHAN, "   • actor_class (agent)")
bot.say(CHAN, "   • provenance (creator, source, authority)")
bot.say(CHAN, "   • presence (state, status, task)")
bot.say(CHAN, "   • heartbeat (last_seen, TTL, healthy)")
bot.say(CHAN, "   • channels I'm in")
bot.say(CHAN, "")
bot.say(CHAN, "Try it — open that URL in your browser, or click my name in the member list.")

if not bot.wait_for_continue():
    sys.exit(1)

# ─── Step 7: Conversational Addressing ─────────
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Step 7 of 7: Conversational Addressing ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "Notice I'm not using slash commands. You talk to me like a person:")
bot.say(CHAN, '   "scout-bot: hello"')
bot.say(CHAN, '   "scout-bot: status"')
bot.say(CHAN, '   "@scout-bot what\'s your provenance?"')
bot.say(CHAN, "")
bot.say(CHAN, "This works on EVERY IRC client — irssi, weechat, Textual, the web client.")
bot.say(CHAN, "Slash commands would fail on any client that isn't ours.")
bot.say(CHAN, "")
bot.say(CHAN, "Try it now — ask me something! Say "next" when you're done playing.")

# Interactive sub-loop for step 7
while True:
    msg = bot.wait_for_owner(timeout=300)
    if msg is None:
        break
    lower = msg.strip().lower()

    # Check for continue
    if lower in ("next", "n", "go", "continue", "ok"):
        break
    for prefix in ("scout-bot:", "scout-bot,", "@scout-bot"):
        if lower.startswith(prefix):
            rest = lower[len(prefix):].strip()
            if rest in ("next", "n", "go", "continue", "ok"):
                lower = "next"
                break
    if lower == "next":
        break

    # Handle addressed messages
    addressed = False
    text = lower
    for prefix in ("scout-bot:", "scout-bot,", "@scout-bot"):
        if lower.startswith(prefix):
            addressed = True
            text = lower[len(prefix):].strip()
            break

    if addressed:
        if any(w in text for w in ("hello", "hi", "hey")):
            bot.say(CHAN, f"{OWNER}: Hey! 👋 I'm scout-bot. I authenticated with did:key, registered as agent, declared my provenance, and I'm heartbeating right now.")
        elif "status" in text:
            bot.say(CHAN, f"{OWNER}: 🤖 agent | 🔑 {did[:45]}... | 📊 active | 💓 heartbeat every 25s")
        elif "provenance" in text or "who made" in text or "creator" in text:
            bot.say(CHAN, f"{OWNER}: Created by chadfowler.com | Source: github.com/chad/freeq | Code: demo-phase1.py")
        elif "help" in text:
            bot.say(CHAN, f"{OWNER}: Try: hello, status, provenance, help")
        else:
            bot.say(CHAN, f"{OWNER}: 👍 I heard you! Try: hello, status, provenance, help")

# ─── Summary ───────────────────────────────────
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Phase 1: Known Actors — Summary ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "What we just demonstrated:")
bot.say(CHAN, "   1. 🔑 did:key SASL auth — zero-infrastructure identity")
bot.say(CHAN, "   2. 🤖 Actor class — agents are visually distinct from humans")
bot.say(CHAN, "   3. 📋 Provenance — machine-readable proof of origin")
bot.say(CHAN, "   4. 📊 Rich presence — 13 structured states beyond online/away")
bot.say(CHAN, "   5. 💓 Heartbeat — automatic liveness detection with TTL")
bot.say(CHAN, "   6. 🌐 REST API — everything queryable as JSON")
bot.say(CHAN, "   7. 💬 Natural addressing — works on every IRC client")
bot.say(CHAN, "")
bot.say(CHAN, "All of this runs over standard IRC. A user on irssi sees scout-bot")
bot.say(CHAN, "as a normal participant. Zero protocol breakage. Zero UX regression.")
bot.say(CHAN, "")
bot.say(CHAN, "👋 Demo complete! scout-bot signing off.")

bot.cmd("PRESENCE :state=offline;status=Demo complete")
time.sleep(0.5)
bot.send_raw("QUIT :Phase 1 demo complete")
time.sleep(1)
print("Done.")
