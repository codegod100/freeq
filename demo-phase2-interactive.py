#!/usr/bin/env python3
"""
Phase 2: Governable Agents — Step-by-Step Interactive Demo
============================================================
Demonstrates governance signals, approval flows, pause/resume/revoke.
Each step waits for chadfowler.com to say 'next' before proceeding.

The bot ("factory") joins #chad-dev, registers as an agent, then walks
through Phase 2 features interactively.
"""

import ssl, socket, time, base64, json, threading, sys, os

sys.stdout.reconfigure(line_buffering=True)

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

CHAN = "#chad-dev"
HOST = "irc.freeq.at"
PORT = 6697
OWNER = "chadfowler.com"
NICK = "factory"

KEY_DIR = os.path.expanduser("~/.freeq/bots/factory")


def _derive_did(pub_bytes):
    ALPHABET = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    mc = b"\xed\x01" + pub_bytes
    n = int.from_bytes(mc, "big")
    result = b""
    while n > 0:
        n, r = divmod(n, 58)
        result = ALPHABET[r : r + 1] + result
    return "did:key:z" + result.decode()


def load_or_create_key():
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
        self.paused = False

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
                    print("  [reader] EOF")
                    break
                buf += data
                while "\r\n" in buf:
                    line, buf = buf.split("\r\n", 1)
                    if line.startswith("PING"):
                        pong = "PONG" + line[4:]
                        try:
                            self.sock.send((pong + "\r\n").encode())
                            print(f"  [reader] {line} → {pong}")
                        except Exception as e:
                            print(f"  [reader] PONG send failed: {e}")
                    self.lines.append(line)
            except socket.timeout:
                continue
            except Exception as e:
                print(f"  [reader] exception: {e}")
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
        self.send_raw(f"USER {self.nick} 0 * :Phase 2 Factory Agent")
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

    def _check_governance(self):
        """Check for governance signals. Returns True if a signal was handled."""
        for i, line in enumerate(self.lines):
            if "freeq.at/governance=pause" in line:
                self.lines = self.lines[i + 1 :]
                self.paused = True
                self.cmd("PRESENCE :state=paused;status=Paused by governance action")
                self.say(CHAN, "⏸️ I've been paused. Waiting for resume...")
                print("  [PAUSED by governance]")
                # Block here until resumed or revoked
                while self.paused:
                    time.sleep(0.3)
                    for j, rline in enumerate(self.lines):
                        if "freeq.at/governance=resume" in rline:
                            self.lines = self.lines[j + 1 :]
                            self.paused = False
                            self.cmd("PRESENCE :state=active;status=Resumed — continuing work")
                            self.say(CHAN, "▶️ Resumed! Continuing where I left off.")
                            print("  [RESUMED by governance]")
                            return True
                        if "freeq.at/governance=revoke" in rline:
                            self.lines = self.lines[j + 1 :]
                            self.say(CHAN, "🚫 I've been revoked. Disconnecting gracefully.")
                            self.cmd("PRESENCE :state=offline;status=Revoked")
                            time.sleep(1)
                            self.send_raw("QUIT :Revoked by governance action")
                            print("  [REVOKED — exiting]")
                            sys.exit(0)
                    # Keep heartbeating while paused
                    self.cmd("HEARTBEAT 60")
                return True
            if "freeq.at/governance=resume" in line:
                # Stale resume (wasn't paused) — just consume it
                self.lines = self.lines[i + 1 :]
                return True
            if "freeq.at/governance=revoke" in line:
                self.lines = self.lines[i + 1 :]
                self.say(CHAN, "🚫 I've been revoked. Disconnecting gracefully.")
                self.cmd("PRESENCE :state=offline;status=Revoked")
                time.sleep(1)
                self.send_raw("QUIT :Revoked by governance action")
                print("  [REVOKED — exiting]")
                sys.exit(0)
        return False

    def wait_for_owner(self, timeout=300):
        deadline = time.time() + timeout
        last_heartbeat = time.time()
        while time.time() < deadline:
            if time.time() - last_heartbeat > 25:
                self.cmd("HEARTBEAT 60")
                last_heartbeat = time.time()
            # Check for governance signals (blocks if paused)
            self._check_governance()
            # Check for owner messages (skip batch/history messages)
            for i, line in enumerate(self.lines):
                # Skip CHATHISTORY batch messages
                if "batch=" in line and f"PRIVMSG {CHAN}" in line:
                    continue
                if f"PRIVMSG {CHAN}" in line and f":{OWNER}!" in line:
                    parts = line.split(f"PRIVMSG {CHAN} :", 1)
                    text = parts[1] if len(parts) > 1 else ""
                    self.lines = self.lines[i + 1 :]
                    return text
            time.sleep(0.2)
        return None

    def wait_for_continue(self):
        self.say(CHAN, "")
        self.say(CHAN, "👉 Say 'next' when you're ready to continue.")
        while True:
            msg = self.wait_for_owner(timeout=300)
            if msg is None:
                return False
            lower = msg.strip().lower()
            if lower in ("next", "n", "go", "continue", "ok", "k", "yes", "y", "ready"):
                return True
            for prefix in (f"{NICK}:", f"{NICK},", f"@{NICK}"):
                if lower.startswith(prefix):
                    rest = lower[len(prefix):].strip()
                    if rest in ("next", "n", "go", "continue", "ok", "k", "yes", "y", "ready"):
                        return True

    def wait_for_approval(self, capability, timeout=120):
        """Wait for an approval TAGMSG from the server."""
        deadline = time.time() + timeout
        last_heartbeat = time.time()
        while time.time() < deadline:
            if time.time() - last_heartbeat > 25:
                self.cmd("HEARTBEAT 60")
                last_heartbeat = time.time()
            for i, line in enumerate(self.lines):
                if f"governance=approval_granted" in line and capability in line:
                    self.lines = self.lines[i + 1 :]
                    return "approved"
                if f"governance=approval_denied" in line and capability in line:
                    self.lines = self.lines[i + 1 :]
                    return "denied"
            time.sleep(0.2)
        return None


# ═══════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════

print("Phase 2: Governable Agents — Interactive Demo")
print("=" * 47)

key, did = load_or_create_key()
print(f"DID: {did[:60]}...")

bot = IRCBot(NICK, key, did)
bot.connect()
bot.register()
print(f"Connected as {NICK}")

# Register as agent + set provenance
bot.cmd("AGENT REGISTER :class=agent")
time.sleep(0.5)
provenance = {
    "actor_did": did,
    "origin_type": "external_import",
    "creator_did": "did:plc:4qsyxmnsblo4luuycm3572bq",
    "implementation_ref": "freeq/demo-phase2.py@HEAD",
    "source_repo": "https://github.com/freeq-irc/freeq",
    "authority_basis": "Operated by server administrator",
    "revocation_authority": "did:plc:4qsyxmnsblo4luuycm3572bq",
}
prov_b64 = base64.urlsafe_b64encode(json.dumps(provenance).encode()).rstrip(b"=").decode()
bot.cmd(f"PROVENANCE :{prov_b64}")
bot.cmd("HEARTBEAT 60")
bot.cmd("PRESENCE :state=idle;status=Waiting for instructions")
time.sleep(0.5)

bot.cmd(f"JOIN {CHAN}")
bot.wait_for("366", 5)
# Wait for CHATHISTORY batch to finish, then drain everything
time.sleep(4)
bot.drain(1.0)
print("Channel history drained, starting demo")

# ─── Intro ──────────────────────────────────────
bot.say(CHAN, "👋 Hey! I'm factory — a demo agent for Phase 2: Governable Agents.")
bot.say(CHAN, "Phase 1 made agents visible. Phase 2 makes them controllable.")
bot.say(CHAN, "I'll walk through each governance feature, one at a time.")
bot.say(CHAN, "There are 5 features to demo.")

if not bot.wait_for_continue():
    sys.exit(1)

# ─── Step 1: Governance Signals ─────────────────
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Step 1 of 5: Governance Signals (Pause / Resume / Revoke) ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "Channel ops can control agents in real time using three commands:")
bot.say(CHAN, "   AGENT PAUSE <nick> [reason]")
bot.say(CHAN, "   AGENT RESUME <nick>")
bot.say(CHAN, "   AGENT REVOKE <nick> [reason]")
bot.say(CHAN, "")
bot.say(CHAN, "These are IRC commands you type in any client. Try it now:")
bot.say(CHAN, "   /quote AGENT PAUSE factory too noisy")
bot.say(CHAN, "")
bot.say(CHAN, "I'll react immediately — watch my presence state change.")
bot.say(CHAN, "(You need to be a channel op. If you're not, I'll simulate it.)")
bot.say(CHAN, "")
bot.say(CHAN, "👉 Try pausing me! Type: /quote AGENT PAUSE factory")
bot.say(CHAN, "   Or say 'next' to skip and I'll simulate it.")

# Wait for either a pause governance signal or 'next'
simulated = False
deadline = time.time() + 120
got_pause = False
while time.time() < deadline:
    # Check for governance pause in lines
    new_lines = []
    for line in bot.lines:
        if not got_pause and "freeq.at/governance=pause" in line:
            got_pause = True
        else:
            new_lines.append(line)
    bot.lines = new_lines

    if got_pause:
        bot.cmd("PRESENCE :state=paused;status=Paused by channel op")
        bot.say(CHAN, "⏸️ I've been paused! My presence state is now 'paused'.")
        bot.say(CHAN, "I won't do any work until I'm resumed.")
        time.sleep(2)
        bot.say(CHAN, "")
        bot.say(CHAN, "Now resume me: /quote AGENT RESUME factory")
        # Wait for resume
        resume_deadline = time.time() + 60
        while time.time() < resume_deadline:
            for i, rline in enumerate(bot.lines):
                if "freeq.at/governance=resume" in rline:
                    bot.lines = bot.lines[i + 1 :]
                    break
            else:
                time.sleep(0.3)
                continue
            break
        bot.cmd("PRESENCE :state=active;status=Resumed")
        bot.say(CHAN, "▶️ Resumed! Back to work.")
        break

    # Check for 'next' from owner
    msg = bot.wait_for_owner(timeout=2)
    if msg and msg.strip().lower() in ("next", "n", "go", "continue", "ok"):
        simulated = True
        break

if simulated:
    bot.say(CHAN, "")
    bot.say(CHAN, "(Simulating pause/resume since you said 'next')")
    bot.cmd("PRESENCE :state=paused;status=Paused by governance demo")
    bot.say(CHAN, "⏸️ [simulated] I'm now paused. Presence state = paused.")
    time.sleep(2)
    bot.cmd("PRESENCE :state=active;status=Resumed from governance demo")
    bot.say(CHAN, "▶️ [simulated] Resumed. Presence state = active.")

bot.say(CHAN, "")
bot.say(CHAN, "Key points about governance signals:")
bot.say(CHAN, "   • They're delivered as IRCv3 TAGMSG with structured tags")
bot.say(CHAN, "   • The agent receives them instantly and reacts")
bot.say(CHAN, "   • Everyone in the channel sees a human-readable NOTICE")
bot.say(CHAN, "   • Legacy clients (irssi, weechat) see it as plain text")
bot.say(CHAN, "   • REVOKE is permanent — the agent disconnects gracefully")

if not bot.wait_for_continue():
    sys.exit(1)

# ─── Step 2: Approval Flows ────────────────────
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Step 2 of 5: Approval Flows ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "Some actions are too risky for an agent to do autonomously.")
bot.say(CHAN, "The approval flow works like this:")
bot.say(CHAN, "")
bot.say(CHAN, "  1. Agent requests approval: APPROVAL_REQUEST #channel :deploy")
bot.say(CHAN, "  2. Server notifies channel ops with a NOTICE")
bot.say(CHAN, "  3. Op approves: AGENT APPROVE factory deploy")
bot.say(CHAN, "  4. Agent receives approval TAGMSG and proceeds")
bot.say(CHAN, "")
bot.say(CHAN, "Let me demonstrate. I'll request approval to 'deploy'...")
time.sleep(1)

bot.cmd("PRESENCE :state=blocked_on_permission;status=Awaiting deploy approval")
bot.cmd(f"APPROVAL_REQUEST {CHAN} :deploy;resource=landing-page-v2")
bot.say(CHAN, "")
bot.say(CHAN, "🔔 I just sent: APPROVAL_REQUEST #chad-dev :deploy;resource=landing-page-v2")
bot.say(CHAN, "My presence is now 'blocked_on_permission'.")
bot.say(CHAN, "")
bot.say(CHAN, "You should see a server NOTICE asking you to approve.")
bot.say(CHAN, "To approve, type: /quote AGENT APPROVE factory deploy")
bot.say(CHAN, "To deny: /quote AGENT DENY factory deploy")
bot.say(CHAN, "Or say 'next' to skip.")

# Wait for approval, denial, or skip
approval_result = None
deadline = time.time() + 120
while time.time() < deadline:
    for i, line in enumerate(bot.lines):
        if "governance=approval_granted" in line and "deploy" in line:
            bot.lines = bot.lines[i + 1 :]
            approval_result = "approved"
            break
        if "governance=approval_denied" in line and "deploy" in line:
            bot.lines = bot.lines[i + 1 :]
            approval_result = "denied"
            break
    if approval_result:
        break
    msg = bot.wait_for_owner(timeout=2)
    if msg and msg.strip().lower() in ("next", "n", "go", "continue", "ok"):
        approval_result = "skipped"
        break

if approval_result == "approved":
    bot.cmd("PRESENCE :state=executing;status=Deploying landing-page-v2")
    bot.say(CHAN, "✅ Approval granted! Deploying...")
    time.sleep(2)
    bot.say(CHAN, "🚀 Deploy complete: landing-page-v2 is live!")
    bot.cmd("PRESENCE :state=active;status=Deploy complete")
elif approval_result == "denied":
    bot.cmd("PRESENCE :state=idle;status=Deploy denied")
    bot.say(CHAN, "❌ Approval denied. I won't deploy. Standing down.")
else:
    bot.say(CHAN, "(Simulating approval since you said 'next')")
    bot.cmd("PRESENCE :state=executing;status=Deploying landing-page-v2")
    bot.say(CHAN, "✅ [simulated] Approval granted. Deploying...")
    time.sleep(2)
    bot.say(CHAN, "🚀 [simulated] Deploy complete!")
    bot.cmd("PRESENCE :state=active;status=Deploy complete")

if not bot.wait_for_continue():
    sys.exit(1)

# ─── Step 3: Spawning Child Agents ─────────────
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Step 3 of 5: Spawning Child Agents ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "A parent agent can spawn short-lived child agents for subtasks.")
bot.say(CHAN, "Children inherit capabilities from the parent and have a TTL.")
bot.say(CHAN, "")
bot.say(CHAN, "I'll spawn a child called 'factory-worker' with a 5-minute TTL:")
time.sleep(1)

bot.cmd(f"AGENT SPAWN {CHAN} :nick=factory-worker;capabilities=post_message;ttl=300;task=build-css")
time.sleep(1)

# Check if spawn succeeded
spawn_ok = False
for line in bot.lines:
    if "factory-worker" in line and "JOIN" in line:
        spawn_ok = True
        break

if spawn_ok:
    bot.say(CHAN, "✅ Spawned factory-worker! It just joined the channel.")
    bot.say(CHAN, "It has:")
    bot.say(CHAN, "   • nick: factory-worker")
    bot.say(CHAN, "   • capabilities: post_message")
    bot.say(CHAN, "   • TTL: 300 seconds (auto-despawn)")
    bot.say(CHAN, "   • task: build-css")
    bot.say(CHAN, "   • parent: factory (me)")
    bot.say(CHAN, "")
    bot.say(CHAN, "I can send messages as the child:")
    bot.cmd(f"AGENT MSG factory-worker {CHAN} :🔨 Working on CSS compilation...")
    time.sleep(1)
    bot.cmd(f"AGENT MSG factory-worker {CHAN} :✅ CSS compiled successfully!")
    time.sleep(1)
    bot.say(CHAN, "")
    bot.say(CHAN, "Now I'll despawn it:")
    bot.cmd("AGENT DESPAWN factory-worker")
    time.sleep(0.5)
    bot.say(CHAN, "✅ factory-worker despawned. It's gone from the channel.")
else:
    bot.say(CHAN, "✅ Sent: AGENT SPAWN #chad-dev :nick=factory-worker;capabilities=post_message;ttl=300;task=build-css")
    bot.say(CHAN, "")
    bot.say(CHAN, "The child agent would:")
    bot.say(CHAN, "   • Join the channel as a separate nick")
    bot.say(CHAN, "   • Have +freeq.at/parent=factory tag on its JOIN")
    bot.say(CHAN, "   • Auto-despawn after 300 seconds")
    bot.say(CHAN, "   • I can send messages as it via AGENT MSG")
    bot.say(CHAN, "   • I can manually despawn it via AGENT DESPAWN")

bot.say(CHAN, "")
bot.say(CHAN, "In the web client, spawned children show the parent agent in their identity card.")
bot.say(CHAN, "Legacy clients just see them as normal nicks that join and part.")

if not bot.wait_for_continue():
    sys.exit(1)

# ─── Step 4: Heartbeat-Driven Liveness ─────────
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Step 4 of 5: Heartbeat Enforcement ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "Phase 1 introduced heartbeat. Phase 2 enforces it.")
bot.say(CHAN, "If an agent stops heartbeating, the server automatically:")
bot.say(CHAN, "")
bot.say(CHAN, "   1× TTL (60s):  transitions to 'degraded' 🟡")
bot.say(CHAN, "   2× TTL (120s): transitions to 'offline' ⚫")
bot.say(CHAN, "   5× TTL (300s): force disconnects the agent")
bot.say(CHAN, "")
bot.say(CHAN, "This prevents zombie agents from occupying channels forever.")
bot.say(CHAN, "The server doesn't trust agents to self-report — it watches the clock.")
bot.say(CHAN, "")
bot.say(CHAN, "I'm currently heartbeating every 25 seconds with a 60-second TTL.")
bot.cmd("HEARTBEAT 60")
bot.say(CHAN, "✅ HEARTBEAT 60 sent just now.")
bot.say(CHAN, "")
bot.say(CHAN, "If I crash, the server detects it and cleans up automatically.")
bot.say(CHAN, "No orphaned bots. No stale member lists. No manual cleanup.")

if not bot.wait_for_continue():
    sys.exit(1)

# ─── Step 5: Putting It All Together ───────────
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Step 5 of 5: The Full Governance Loop ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "Let me show the full loop as a realistic scenario:")
bot.say(CHAN, "")
bot.say(CHAN, "Scenario: You ask me to build and deploy a landing page.")
bot.say(CHAN, "")
bot.say(CHAN, "Say 'factory: build a landing page' to kick it off.")
bot.say(CHAN, "Or say 'next' to skip.")

# Wait for trigger or skip
triggered = False
deadline = time.time() + 120
while time.time() < deadline:
    msg = bot.wait_for_owner(timeout=2)
    if msg:
        lower = msg.strip().lower()
        if lower in ("next", "n"):
            break
        for prefix in (f"{NICK}:", f"{NICK},", f"@{NICK}"):
            if lower.startswith(prefix):
                triggered = True
                break
        if triggered:
            break

if triggered or True:
    # Phase: Accept task
    bot.cmd("PRESENCE :state=active;status=Accepted task: build landing page")
    bot.say(CHAN, "👍 Got it. Building a landing page. Here's my plan:")
    bot.say(CHAN, "   1. Generate HTML/CSS")
    bot.say(CHAN, "   2. Request deploy approval")
    bot.say(CHAN, "   3. Deploy (if approved)")
    time.sleep(1)

    # Phase: Working
    bot.cmd("PRESENCE :state=executing;status=Generating HTML and CSS")
    bot.say(CHAN, "🔨 Generating HTML...")
    time.sleep(2)
    bot.say(CHAN, "🔨 Generating CSS...")
    time.sleep(2)
    bot.say(CHAN, "✅ Build complete. Ready to deploy.")
    time.sleep(1)

    # Phase: Request approval
    bot.cmd("PRESENCE :state=blocked_on_permission;status=Awaiting deploy approval for landing page")
    bot.cmd(f"APPROVAL_REQUEST {CHAN} :deploy;resource=landing-page")
    bot.say(CHAN, "")
    bot.say(CHAN, "🔔 I need approval to deploy. My presence is now 'blocked_on_permission'.")
    bot.say(CHAN, "")
    bot.say(CHAN, "Approve: /quote AGENT APPROVE factory deploy")
    bot.say(CHAN, "Deny: /quote AGENT DENY factory deploy not yet")
    bot.say(CHAN, "Or pause me: /quote AGENT PAUSE factory hold on")
    bot.say(CHAN, "")
    bot.say(CHAN, "I'll wait. (Or say 'next' to simulate approval.)")

    # Wait for approval/deny/pause/next
    result = None
    deadline = time.time() + 180
    while time.time() < deadline:
        # Scan lines for approval/deny/pause signals
        remaining = []
        for line in bot.lines:
            if result:
                remaining.append(line)
                continue
            if "governance=approval_granted" in line and "deploy" in line:
                result = "approved"
            elif "governance=approval_denied" in line and "deploy" in line:
                result = "denied"
            elif "freeq.at/governance=pause" in line:
                bot.cmd("PRESENCE :state=paused;status=Paused while awaiting deploy approval")
                bot.say(CHAN, "⏸️ Paused! I'll remember I was waiting for deploy approval.")
                bot.say(CHAN, "Resume me with: /quote AGENT RESUME factory")
                # Block until resumed
                while True:
                    for j, rline in enumerate(bot.lines):
                        if "freeq.at/governance=resume" in rline:
                            bot.lines = bot.lines[j + 1:]
                            bot.cmd("PRESENCE :state=blocked_on_permission;status=Resumed — still awaiting deploy approval")
                            bot.say(CHAN, "▶️ Resumed. Still waiting for deploy approval.")
                            break
                    else:
                        time.sleep(0.5)
                        continue
                    break
            else:
                remaining.append(line)
        bot.lines = remaining
        if result:
            break
        msg = bot.wait_for_owner(timeout=2)
        if msg and msg.strip().lower() in ("next", "n", "go", "continue", "ok"):
            result = "simulated"
            break

    if result == "approved":
        bot.cmd("PRESENCE :state=executing;status=Deploying landing page")
        bot.say(CHAN, "✅ Approval granted! Deploying...")
        time.sleep(3)
        bot.say(CHAN, "🚀 Deployed! https://landing-page.example.com is live.")
        bot.cmd("PRESENCE :state=idle;status=Task complete — landing page deployed")
    elif result == "denied":
        bot.cmd("PRESENCE :state=idle;status=Deploy denied — standing down")
        bot.say(CHAN, "❌ Deploy denied. Standing down. Build artifacts preserved.")
    else:
        bot.say(CHAN, "(Simulating approval)")
        bot.cmd("PRESENCE :state=executing;status=Deploying landing page")
        bot.say(CHAN, "✅ [simulated] Deploying...")
        time.sleep(2)
        bot.say(CHAN, "🚀 [simulated] Deployed!")
        bot.cmd("PRESENCE :state=idle;status=Task complete")

# ─── Summary ───────────────────────────────────
bot.say(CHAN, "")
bot.say(CHAN, "━━━ Phase 2: Governable Agents — Summary ━━━")
bot.say(CHAN, "")
bot.say(CHAN, "What we demonstrated:")
bot.say(CHAN, "   1. ⏸️ Pause/Resume/Revoke — real-time agent governance")
bot.say(CHAN, "   2. 🔔 Approval flows — agents request permission for risky actions")
bot.say(CHAN, "   3. 👶 Child agents — parent spawns workers with TTL")
bot.say(CHAN, "   4. 💓 Heartbeat enforcement — server detects dead agents")
bot.say(CHAN, "   5. 🔄 Full governance loop — task → build → approve → deploy")
bot.say(CHAN, "")
bot.say(CHAN, "Everything visible in plain text for legacy IRC clients.")
bot.say(CHAN, "Rich clients get structured TAGMSG tags for UI integration.")
bot.say(CHAN, "")
bot.say(CHAN, "Phase 1 answered: 'Who is this agent?'")
bot.say(CHAN, "Phase 2 answers: 'What can it do, and who controls it?'")
bot.say(CHAN, "")
bot.say(CHAN, "👋 factory signing off. Demo complete!")

bot.cmd("PRESENCE :state=offline;status=Demo complete")
time.sleep(0.5)
bot.send_raw("QUIT :Phase 2 demo complete")
time.sleep(1)
print("Done.")
