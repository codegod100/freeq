# Client screenshot staging

How the `/clients/` screenshots (`freeq-site/static/shots/*.png`) were staged
and captured — fully scripted against **production** (irc.freeq.at) so real
identity badges, avatars, and signing locks appear. Re-run this whenever the
clients change enough to warrant fresh shots.

## The scene

Channel `#ship-it`, topic "release train — humans + agents". Cast:

| Who | What | How |
|---|---|---|
| `chadfowler.com` | real human, verified + signed | the signed-in macOS app |
| `relay-agent` | did:key agent | `freeq-bot-kit-js/examples/stage-shipit.ts` |
| `ana` | guest human | `freeq-tui` in tmux (isolated `HOME`) |
| `maya` | guest human | same script as relay-agent |
| `riley` / `sam` | guest viewers | iOS simulator / web (Playwright) |

Six-message conversation: ana's opener → agent ack + 2 task events
(`+freeq.at/event` tags) → maya's confirmation → 🎉 reaction → chad's
(edited) closer. Server history stays clean (join/part and agent-register
noise is not replayed), so **fresh client joins see a pristine buffer** —
stage once, capture forever.

## Steps

1. **Conductor** (holds relay-agent + maya connections for member lists):
   `cd freeq-bot-kit-js && npx tsx examples/stage-shipit.ts`
   — joins, sets topic (needs op), then WAITS for a message matching
   "deploy preview" before performing.
2. **TUI (ana)**: `tmux new-session -d -s freeqshot -x 120 -y 32 \
   'HOME=/tmp/stage-home target/release/freeq-tui -n ana'`, then
   `tmux send-keys` the `/join` and the opener line. Isolated `HOME` keeps
   the operator's real TUI session/OAuth out of it.
3. **Reaction**: `npx tsx examples/stage-react.ts` (one-shot guest; finds the
   "5/5 green" msgid via CHATHISTORY, reacts 🎉 — server persists it).
4. **macOS**: quit app → `defaults write at.freeq.macos freeq.lastChannel
   "#ship-it"` (+ append to `freeq.channels`) → relaunch → it auto-joins and
   opens the channel. Chad's line is typed via System Events keystrokes
   (ASCII only — emoji must go through pbcopy + ⌘V). To de-noise the live
   buffer, purge `#ship-it` rows from the container's
   `Caches/at.freeq.macos/messages.sqlite` and relaunch (rebuilds from clean
   server history). Window sized 1440×900 via System Events; captured with
   `screencapture -l<id>` (ids from `winid.swift`).
5. **Web**: `cd freeq-app && npx tsx stage-web-capture.ts` — Playwright,
   guest login, pre-seeds `freeq-onboarding-done`, dismisses the MOTD modal,
   waits for history, 1440×900@2x.
6. **iOS**: build for simulator, `simctl install`, then launch with
   `SIMCTL_CHILD_FREEQ_TEST_GUEST=riley SIMCTL_CHILD_FREEQ_TEST_OPEN="#ship-it"`
   (+ pre-seed `freeq.channels` via `simctl spawn booted defaults write
   at.freeq.ios`). Capture: `simctl io booted screenshot`.
7. **TUI capture**: attach the tmux session in a Terminal window (custom
   title set via AppleScript), capture with `screencapture -l<id>`.

## Gotchas learned the hard way

- **Guest ghost nicks**: a killed TUI leaves its nick held server-side for
  ~90s; reconnecting too fast gets `ana1`. Wait out the reap.
- **keystroke can't type emoji** — it mangles to ASCII. pbcopy + ⌘V.
- **bot-kit announces on start** ("registered as agent" server ack in the
  channel) — don't start throwaway bot-kit sessions in the staged channel;
  use a plain `FreeqClient` guest for utility scripts.
- Scripts importing bot-kit/sdk must live under `freeq-bot-kit-js/examples/`
  (or `freeq-app/` for Playwright) — module resolution fails outside.

## Bugs this staging caught (fixed, with tests)

- **TUI**: history replays (JOIN replay + double CHATHISTORY) duplicated
  edited messages — three-part dedup fix in `freeq-tui/src/app.rs`
  (`edit_aliases` + push-path dedup + batch-edit applies to live buffer too).
- **iOS**: same class of bug — `ChatMessage.editOf` + `appendIfNew` guards +
  `applyEdit` re-keying ported from macOS (`EditDedupTests.swift`).
- **iOS smart replies**: observed the suggestion bar leak its LLM preamble
  ("Here are three natural replies that Riley could send next:") — rerolls
  correctly on relaunch; not yet fixed at the prompt level. TODO.
