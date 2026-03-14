#!/usr/bin/env python3
"""
Agent-Native Architecture Demo — exercises all 5 phases live in #chad-dev.
Connects multiple agents via did:key SASL auth, runs a mini factory build,
demonstrates governance, coordination, spawning, and budgets.
"""

import ssl, socket, time, base64, hashlib, json, threading, sys

# --- ed25519 key handling (uses PyNaCl or falls back to cryptography) ---
try:
    from nacl.signing import SigningKey
    def load_key(path):
        with open(path, 'rb') as f:
            seed = f.read(32)
        return SigningKey(seed)
    def sign(key, data):
        return key.sign(data).signature
    def pub_bytes(key):
        return bytes(key.verify_key)
except ImportError:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization
    def load_key(path):
        with open(path, 'rb') as f:
            seed = f.read(32)
        return Ed25519PrivateKey.from_private_bytes(seed)
    def sign(key, data):
        return key.sign(data)
    def pub_bytes(key):
        return key.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)

def make_did_key(pub):
    """Encode ed25519 public key as did:key (multicodec 0xed01)."""
    multicodec = b'\xed\x01' + pub
    # base58btc encode with 'z' prefix
    import hashlib
    ALPHABET = b'123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
    n = int.from_bytes(multicodec, 'big')
    result = b''
    while n > 0:
        n, r = divmod(n, 58)
        result = ALPHABET[r:r+1] + result
    for b in multicodec:
        if b == 0:
            result = ALPHABET[0:1] + result
        else:
            break
    return 'did:key:z' + result.decode()

# --- IRC connection class ---
class IRCAgent:
    def __init__(self, nick, key_path=None):
        self.nick = nick
        self.key = load_key(key_path) if key_path else None
        self.did = make_did_key(pub_bytes(self.key)) if self.key else None
        self.sock = None
        self.buf = ""
        self.running = True
        self.lines = []

    def connect(self):
        ctx = ssl.create_default_context()
        raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock = ctx.wrap_socket(raw, server_hostname="irc.freeq.at")
        self.sock.settimeout(5)
        self.sock.connect(("irc.freeq.at", 6697))
        # Start reader thread
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    def _read_loop(self):
        while self.running:
            try:
                data = self.sock.recv(4096).decode(errors='replace')
                if not data:
                    break
                self.buf += data
                while '\r\n' in self.buf:
                    line, self.buf = self.buf.split('\r\n', 1)
                    self.lines.append(line)
                    if line.startswith('PING'):
                        pong = line.replace('PING', 'PONG', 1)
                        self.send_raw(pong)
            except socket.timeout:
                continue
            except:
                break

    def send_raw(self, msg):
        self.sock.send((msg + "\r\n").encode())

    def wait_for(self, pattern, timeout=8):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for i, line in enumerate(self.lines):
                if pattern in line:
                    self.lines = self.lines[i+1:]
                    return line
            time.sleep(0.1)
        return None

    def drain(self, wait=0.3):
        time.sleep(wait)
        self.lines.clear()

    def register(self):
        """Full IRC registration with SASL did:key auth."""
        self.send_raw("CAP LS 302")
        self.send_raw(f"NICK {self.nick}")
        self.send_raw(f"USER {self.nick} 0 * :Agent-Native Demo Bot")

        if self.key:
            self.send_raw("CAP REQ :sasl message-tags server-time echo-message")
            self.wait_for("CAP", 5)
            self.send_raw("AUTHENTICATE ATPROTO-CHALLENGE")
            
            # Wait for challenge
            challenge_line = self.wait_for("AUTHENTICATE", 5)
            if challenge_line and '+' in challenge_line:
                # Parse challenge: base64(did\0session\0nonce\0timestamp)
                parts = challenge_line.split(' ')
                challenge_b64 = parts[-1] if parts[-1] != '+' else None
                if challenge_b64 and challenge_b64 != '+':
                    challenge_bytes = base64.b64decode(challenge_b64)
                    # Sign the challenge
                    signature = sign(self.key, challenge_bytes)
                    # Response: base64(did\0signature_b64)
                    sig_b64 = base64.urlsafe_b64encode(signature).rstrip(b'=').decode()
                    response = f"{self.did}\0{sig_b64}"
                    resp_b64 = base64.b64encode(response.encode()).decode()
                    self.send_raw(f"AUTHENTICATE {resp_b64}")
                    
                    result = self.wait_for("90", 5)  # 903 success or 904 failure
                    if result and "903" in result:
                        print(f"  ✅ {self.nick} authenticated as {self.did[:40]}...")
                    else:
                        print(f"  ⚠ {self.nick} auth result: {result}")
            
            self.send_raw("CAP END")
        else:
            self.send_raw("CAP END")
        
        welcome = self.wait_for("001", 5)
        if welcome:
            print(f"  ✅ {self.nick} connected")
        self.drain()

    def join(self, channel):
        self.send_raw(f"JOIN {channel}")
        self.wait_for("JOIN", 3)
        self.drain(0.5)

    def say(self, channel, text):
        self.send_raw(f"PRIVMSG {channel} :{text}")
        time.sleep(0.4)

    def cmd(self, raw):
        self.send_raw(raw)
        time.sleep(0.3)


# Generate fresh keys for demo agents
import os, tempfile

def make_agent_key(name):
    """Generate a fresh ed25519 key for a demo agent."""
    seed = os.urandom(32)
    path = os.path.join(tempfile.gettempdir(), f"freeq-demo-{name}.key")
    with open(path, 'wb') as f:
        f.write(seed)
    return path

# ============================================================
# DEMO SCRIPT
# ============================================================

CHAN = "#chad-dev"

print("=" * 60)
print("  Agent-Native Architecture — Live Demo")
print("  Channel: #chad-dev on irc.freeq.at")
print("=" * 60)
print()

# --- Create agents ---
print("🔑 Generating agent identities...")
factory_key = make_agent_key("factory")
auditor_key = make_agent_key("auditor")

factory = IRCAgent("factory-bot", factory_key)
auditor = IRCAgent("auditor-bot", auditor_key)

print(f"  factory-bot: {factory.did[:50]}...")
print(f"  auditor-bot: {auditor.did[:50]}...")
print()

# --- Connect & authenticate ---
print("📡 Connecting agents...")
factory.connect()
auditor.connect()
factory.register()
auditor.register()
print()

# --- Join channel ---
print(f"📢 Joining {CHAN}...")
factory.join(CHAN)
auditor.join(CHAN)
time.sleep(1)

# ============================================================
# PHASE 1: Known Actors
# ============================================================
print("▶ Phase 1: Known Actors")

factory.say(CHAN, "👋 factory-bot online — demonstrating Agent-Native Architecture (5 phases)")
time.sleep(0.5)

# Register as agent
factory.cmd("AGENT REGISTER class=agent")
factory.wait_for("registered", 3)
auditor.cmd("AGENT REGISTER class=agent")
auditor.wait_for("registered", 3)

factory.say(CHAN, "🤖 Phase 1: Known Actors — both agents registered with actor_class=agent")

# Submit provenance
prov = base64.urlsafe_b64encode(json.dumps({
    "origin_type": "template",
    "creator_did": "did:plc:4qsyxmnsblo4luuycm3572bq",
    "implementation_ref": "freeq-bots/factory@demo",
    "revocation_authority": "did:plc:4qsyxmnsblo4luuycm3572bq"
}).encode()).rstrip(b'=').decode()
factory.cmd(f"PROVENANCE :{prov}")
factory.wait_for("Provenance", 3)

# Set presence
factory.cmd("PRESENCE active :building things :30")
factory.wait_for("Presence", 3)

# Heartbeat
factory.cmd("HEARTBEAT 30")

factory.say(CHAN, "📋 Provenance submitted (creator: chadfowler.com), presence: active, heartbeat: 30s")
time.sleep(1)

# ============================================================
# PHASE 2: Governable Agents
# ============================================================
print("▶ Phase 2: Governable Agents")

factory.say(CHAN, "🔧 Phase 2: Governable Agents — auditor-bot will demonstrate governance controls")

# Auditor requests approval
auditor.cmd(f"APPROVAL_REQUEST {CHAN} :code_review;resource=landing-page")
auditor.wait_for("Approval requested", 3)
time.sleep(0.5)

auditor.say(CHAN, "🔔 auditor-bot requested approval for 'code_review'. Channel ops can: AGENT APPROVE auditor-bot code_review")
time.sleep(1)

# ============================================================
# PHASE 3: Coordinated Work
# ============================================================
print("▶ Phase 3: Coordinated Work")

factory.say(CHAN, "📋 Phase 3: Coordinated Work — factory-bot building a landing page")

# Create task via structured events
task_id = f"TASK{int(time.time()) % 100000:05d}"

# Task request
factory.cmd(f'@+freeq.at/event=task_request;+freeq.at/task-id={task_id};+freeq.at/payload={{"description":"Build+landing+page"}} TAGMSG {CHAN}')
factory.say(CHAN, f"📋 New task: Build a landing page (task: {task_id})")
time.sleep(0.8)

# Phase: specifying
factory.cmd(f'@+freeq.at/event=task_update;+freeq.at/ref={task_id};+freeq.at/payload={{"phase":"specifying","summary":"Clarifying+requirements"}} TAGMSG {CHAN}')
factory.say(CHAN, "📝 [specifying] Clarifying requirements — React + Tailwind, hero section, CTA")
time.sleep(0.8)

# Phase: designing
factory.cmd(f'@+freeq.at/event=task_update;+freeq.at/ref={task_id};+freeq.at/payload={{"phase":"designing","summary":"Component+architecture"}} TAGMSG {CHAN}')
factory.say(CHAN, "🏗 [designing] Component architecture: Hero, Features, CTA, Footer")
time.sleep(0.8)

# Phase: building
factory.cmd(f'@+freeq.at/event=task_update;+freeq.at/ref={task_id};+freeq.at/payload={{"phase":"building","summary":"Writing+code"}} TAGMSG {CHAN}')
factory.say(CHAN, "🔨 [building] Writing code — 4 components, 380 lines")
time.sleep(0.8)

# Evidence: test results
factory.cmd(f'@+freeq.at/event=evidence_attach;+freeq.at/ref={task_id};+freeq.at/payload={{"type":"test_result","summary":"8/8+passed"}} TAGMSG {CHAN}')
factory.say(CHAN, "📎 Evidence (test_result): 8/8 tests passed ✅")
time.sleep(0.5)

# Evidence: architecture doc
factory.cmd(f'@+freeq.at/event=evidence_attach;+freeq.at/ref={task_id};+freeq.at/payload={{"type":"architecture_doc","summary":"React+Tailwind+4+components"}} TAGMSG {CHAN}')
factory.say(CHAN, "📎 Evidence (architecture_doc): React + Tailwind, 4 components")
time.sleep(0.5)

# ============================================================
# PHASE 4: Spawning
# ============================================================
print("▶ Phase 4: Interop & Spawning")

factory.say(CHAN, f"🔀 Phase 4: Spawning qa-worker sub-agent for testing (TTL: 30s)")

factory.cmd(f"AGENT SPAWN {CHAN} :nick=qa-worker;capabilities=post_message,call_tool;ttl=30;task={task_id}")
factory.wait_for("Spawned", 3)
time.sleep(0.5)

# Send messages as the spawned child
factory.cmd(f"AGENT MSG qa-worker {CHAN} :🧪 Running test suite on landing page...")
time.sleep(0.8)
factory.cmd(f"AGENT MSG qa-worker {CHAN} :✅ 8/8 tests passed — accessibility, responsive, performance all green")
time.sleep(0.8)
factory.cmd(f"AGENT MSG qa-worker {CHAN} :📋 QA complete. Recommending deploy.")
time.sleep(0.5)

# Despawn the child
factory.cmd("AGENT DESPAWN qa-worker")
factory.wait_for("Despawned", 3)
factory.say(CHAN, "🔀 qa-worker completed and despawned")
time.sleep(0.5)

# ============================================================
# PHASE 5: Economic Controls
# ============================================================
print("▶ Phase 5: Economic Controls")

factory.say(CHAN, "💰 Phase 5: Economic Controls — setting channel budget and reporting spend")

# Set budget (factory is channel op as first joiner... or we try)
factory.cmd(f"BUDGET {CHAN} :max=25;unit=usd;period=per_day;sponsor=did:plc:4qsyxmnsblo4luuycm3572bq;warn=0.8;hard=true")
factory.wait_for("Budget", 3)
time.sleep(0.5)

# Report spend from the "build"
factory.cmd(f"SPEND {CHAN} :amount=3.20;unit=usd;desc=claude-sonnet: 12k/4k tokens (specifying);task={task_id}")
time.sleep(0.3)
factory.cmd(f"SPEND {CHAN} :amount=4.80;unit=usd;desc=claude-sonnet: 18k/6k tokens (designing);task={task_id}")
time.sleep(0.3)
factory.cmd(f"SPEND {CHAN} :amount=8.50;unit=usd;desc=claude-sonnet: 32k/11k tokens (building);task={task_id}")
time.sleep(0.3)
factory.cmd(f"SPEND {CHAN} :amount=2.10;unit=usd;desc=claude-sonnet: 8k/3k tokens (testing);task={task_id}")
time.drain(0.5)

factory.say(CHAN, f"💰 Total spend: $18.60 / $25.00 budget (74.4%) — 4 LLM calls for task {task_id}")

# Query budget
factory.cmd(f"BUDGET {CHAN}")
factory.wait_for("NOTICE", 3)
time.sleep(0.5)

# One more spend to cross the 80% threshold
factory.cmd(f"SPEND {CHAN} :amount=2.50;unit=usd;desc=claude-sonnet: deploy prep;task={task_id}")
time.sleep(1)

# ============================================================
# Task Complete
# ============================================================
print("▶ Task Completion")

factory.cmd(f'@+freeq.at/event=task_complete;+freeq.at/ref={task_id};+freeq.at/payload={{"summary":"Landing+page+deployed","url":"https://demo.example.com"}} TAGMSG {CHAN}')
factory.say(CHAN, f"🎉 Task complete: Landing page deployed — https://demo.example.com (task: {task_id})")
time.sleep(0.5)

# ============================================================
# Manifest (Phase 4 bonus)
# ============================================================
manifest_toml = """
[agent]
display_name = "factory-bot"
actor_class = "agent"
description = "Software factory — builds apps from natural language specs"
source_repo = "https://github.com/chad/freeq"
version = "0.1.0"

[provenance]
origin_type = "template"
creator_did = "did:plc:4qsyxmnsblo4luuycm3572bq"
revocation_authority = "did:plc:4qsyxmnsblo4luuycm3572bq"
authority_basis = "Operated by freeq core team"

[capabilities]
default = ["post_message", "read_channel", "call_tool"]

[presence]
heartbeat_interval_seconds = 30
"""
manifest_b64 = base64.b64encode(manifest_toml.encode()).decode()
factory.cmd(f"AGENT MANIFEST {manifest_b64}")
factory.wait_for("Manifest", 3)
factory.say(CHAN, "📄 Agent manifest registered — declarative identity, capabilities, and provenance in TOML")
time.sleep(0.5)

# ============================================================
# Summary
# ============================================================
print("▶ Summary")

factory.say(CHAN, "─── Agent-Native Demo Complete ───")
time.sleep(0.3)
factory.say(CHAN, "Phase 1: ✅ Actor registration, provenance, presence, heartbeat")
time.sleep(0.2)
factory.say(CHAN, "Phase 2: ✅ Governance signals, approval workflows")
time.sleep(0.2)
factory.say(CHAN, "Phase 3: ✅ Typed coordination events, evidence attachments, task lifecycle")
time.sleep(0.2)
factory.say(CHAN, "Phase 4: ✅ Agent manifests, sub-agent spawning with TTL, child messaging")
time.sleep(0.2)
factory.say(CHAN, "Phase 5: ✅ Channel budgets, spend tracking, threshold warnings")
time.sleep(0.2)
factory.say(CHAN, "167 tests • 27 SDK methods • 11 REST endpoints • 7 new IRC commands")
time.sleep(0.2)
factory.say(CHAN, "factory-bot and auditor-bot staying online in channel. Try: /api/v1/agents/manifests or /api/v1/channels/chad-dev/budget")

# Set presence to idle
factory.cmd("PRESENCE online :demo complete, standing by :30")
auditor.cmd("PRESENCE online :monitoring :30")

print()
print("=" * 60)
print("  Demo complete! Agents staying connected.")
print("  Press Ctrl+C to disconnect.")
print("=" * 60)

# Keep agents alive with heartbeats
try:
    while True:
        factory.cmd("HEARTBEAT 30")
        auditor.cmd("HEARTBEAT 30")
        time.sleep(25)
except KeyboardInterrupt:
    print("\nDisconnecting agents...")
    factory.say(CHAN, "👋 factory-bot signing off")
    auditor.say(CHAN, "👋 auditor-bot signing off")
    factory.send_raw("QUIT :demo over")
    auditor.send_raw("QUIT :demo over")
    time.sleep(1)
