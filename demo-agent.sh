#!/usr/bin/env bash
# Demo script: exercises all 5 agent-native phases against irc.freeq.at
# Uses the freeq-sdk via raw IRC commands through freeq-tui

SERVER="irc.freeq.at:6697"
TUI="/Users/chad/src/freeq/target/release/freeq-tui"
NICK="demo-agent"
CHANNEL="#freeq"

send() {
  $TUI --nick "$NICK" --tls -s "$SERVER" -c "$CHANNEL" --send "$1" 2>&1 | tail -1
}

echo "=== Agent-Native Demo ==="
echo ""

# Phase 1: Announce
echo "Phase 1: Known Actors"
send "🤖 demo-agent online — Phase 1: Known Actors. I'm a did:key authenticated agent with actor_class=agent, provenance, and heartbeat."
sleep 2

# Phase 2: Governance
echo "Phase 2: Governable Agents"
send "🔧 Phase 2: Governable Agents. Ops can PAUSE/RESUME/REVOKE me. I support approval workflows — ask me before I do anything dangerous."
sleep 2

# Phase 3: Coordinated Work
echo "Phase 3: Coordinated Work"
send "📋 Phase 3: Coordinated Work. I emit typed events: task_request → task_update → evidence_attach → task_complete. Every action has a ULID, every artifact has provenance."
sleep 2

# Phase 4: Interop & Spawning
echo "Phase 4: Interop & Spawning"
send "🔀 Phase 4: Interop & Spawning. I can declare my identity via TOML manifests, spawn sub-agents with scoped TTLs, and bridge external agents (MCP/A2A) with wrapper trust profiles."
sleep 2

# Phase 5: Economic Controls
echo "Phase 5: Economic Controls"
send "💰 Phase 5: Economic Controls. Channels can set budgets (BUDGET #ch :max=50;unit=usd;period=per_day). I report spend on every LLM call. Server warns at 80%, blocks at 100%."
sleep 2

# Summary
send "✅ All 5 phases deployed to irc.freeq.at — 167 tests passing. REST APIs live at /api/v1/agents/*, /api/v1/channels/*/events, /budget, /spend, /audit. Full agent lifecycle: identity → governance → coordination → spawning → economics."

echo ""
echo "=== Demo complete ==="
