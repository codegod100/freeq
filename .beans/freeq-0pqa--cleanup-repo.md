---
# freeq-0pqa
title: cleanup repo
status: completed
type: task
priority: normal
created_at: 2026-07-20T16:51:00Z
updated_at: 2026-07-20T18:51:13Z
---

Remove dead project folders and figure out where cruft is.

Completed:
- Removed dead `freeq-windows-app/` WPF prototype and stale top-level `demo*.py` / `demo-agent.sh` scripts
- Archived `freeq-textual` Nix flake outputs (packages and apps) and removed the now-empty `Justfile`
- Archived the `freeq-py` Python/Textual TUI project and simplified the flake to a minimal Rust devShell
- Identified remaining questionable cruft: `freeq-webui`, `freeq-windows-core`, outdated Windows docs, root-level audit snapshots
