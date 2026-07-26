#!/usr/bin/env nu
# Deploy freeq-web4 to freeq.boxd (https://freeq.boxd.sh).
#
# Flow (default):
#   1. Commit dirty freeq-web4 changes with jj (if any)
#   2. Rsync tree to the VM (default — no GitHub required)
#   3. On the VM: nix develop + gleam deps + restart systemd unit
#   4. Point freeq.boxd.sh proxy at PORT (4004) and stop freeq-web3
#
# Usage:
#   nu freeq-web4/script/deploy-boxd.nu
#   nu freeq-web4/script/deploy-boxd.nu -m "Deploy web4 to freeq.boxd"
#   nu freeq-web4/script/deploy-boxd.nu --no-commit
#   nu freeq-web4/script/deploy-boxd.nu --skip-restart
#   nu freeq-web4/script/deploy-boxd.nu --keep-web3   # leave web3 running

def main [
  --message (-m): string = ""          # commit message (prompted if empty + dirty)
  --no-commit                          # skip jj commit even if dirty
  --host: string = "freeq.boxd"        # SSH host (boxd ssh-config alias)
  --remote-dir: string = "/home/boxd/freeq-web4"
  --port: int = 4004                   # HTTP listen + proxy target
  --skip-build                         # skip gleam deps download
  --skip-restart                       # skip systemctl restart
  --keep-web3                          # do not stop freeq-web3.service
  --skip-proxy                         # do not retarget freeq.boxd.sh proxy
] {
  let root = (find_repo_root)
  let web4 = ($root | path join "freeq-web4")
  if not ($web4 | path exists) {
    error make {msg: $"freeq-web4 not found under ($root)"}
  }

  print $"==> repo: ($root)"
  cd $root

  # ── 1. Commit (jj) ─────────────────────────────────────────────────
  if not $no_commit {
    if (jj_has_web4_changes) {
      mut msg = $message
      if ($msg | str trim | is-empty) {
        $msg = (input "commit message: ")
      }
      if ($msg | str trim | is-empty) {
        error make {msg: "empty commit message; aborting"}
      }
      print $"==> jj commit: ($msg)"
      ^jj --config "ui.paginate=never" commit -m $msg
      ^jj --config "ui.paginate=never" bookmark set main -r "@-"
    } else {
      print "==> working tree clean for freeq-web4 (no commit)"
    }
  } else {
    print "==> --no-commit: leaving local history alone"
  }

  # ── 2. Rsync ───────────────────────────────────────────────────────
  print $"==> rsync freeq-web4 → ($host):($remote_dir)/"
  rsync_web4 $web4 $"($host):($remote_dir)/"

  # ── 3. Ensure env + systemd unit on VM ─────────────────────────────
  ensure_remote_unit $host $remote_dir $port

  # ── 4. Build + restart on VM ───────────────────────────────────────
  let do_build = (not $skip_build)
  let do_restart = (not $skip_restart)

  mut lines = [
    "set -euo pipefail"
    $"cd ($remote_dir)"
    'export PATH="/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:$PATH"'
    "set -a"
    ". /home/boxd/freeq-web4.env"
    "set +a"
  ]

  if $do_build {
    $lines = (
      $lines | append [
        "echo '==> nix develop + gleam deps download + build'"
        # Pre-build so systemd start only boots the BEAM (first compile is slow).
        # </dev/null: nix must not drain bash -s stdin
        $"nix develop ($remote_dir) -c bash -lc 'set -euo pipefail; gleam deps download; gleam build' </dev/null"
      ]
    )
  }

  if $do_restart {
    # Wait loop avoids $(...) / $((...)) so Nu does not expand them locally.
    let wait_loop = ([
      $"echo '==> wait for freeq-web4 on port ($port)'"
      "i=0"
      "while [ \"$i\" -lt 90 ]; do"
      $"  if systemctl --user is-active freeq-web4.service >/dev/null 2>&1 && ss -ltn | grep -qE \":($port)\\b\"; then"
      "    break"
      "  fi"
      "  i=`expr \"$i\" + 1`"
      "  sleep 2"
      "done"
    ] | str join "\n")

    $lines = (
      $lines | append [
        "echo '==> systemctl --user daemon-reload + restart freeq-web4'"
        "systemctl --user daemon-reload"
        "systemctl --user enable freeq-web4.service"
        "systemctl --user restart freeq-web4.service"
        $wait_loop
        "systemctl --user is-active freeq-web4.service"
        $"ss -ltn | grep -E \":($port)\\b\" || echo \"WARN: nothing on :($port) yet\""
        $"curl -sS -o /dev/null -w \"local_http=%{http_code}\\n\" --max-time 15 http://127.0.0.1:($port)/health || true"
        $"curl -sS -o /dev/null -w \"local_chat=%{http_code}\\n\" --max-time 15 http://127.0.0.1:($port)/chat || true"
      ]
    )
  }

  if not $keep_web3 {
    $lines = (
      $lines | append [
        "echo '==> stop freeq-web3 (web4 owns freeq.boxd.sh)'"
        "systemctl --user stop freeq-web3.service 2>/dev/null || true"
        "systemctl --user disable freeq-web3.service 2>/dev/null || true"
      ]
    )
  }

  let remote = ($lines | str join "\n")
  print $"==> ($host): build/restart freeq-web4"
  let remote_script = $"/tmp/freeq-web4-deploy-(random chars --length 8).sh"
  [
    "set -euo pipefail"
    $"cat > ($remote_script) <<'FREEQ_WEB4_DEPLOY_EOF'"
    $remote
    "FREEQ_WEB4_DEPLOY_EOF"
    $"bash ($remote_script)"
    $"rm -f ($remote_script)"
  ] | str join "\n" | ^ssh $host bash -s

  # ── 5. Proxy ───────────────────────────────────────────────────────
  if not $skip_proxy {
    print $"==> boxd proxy set-port freeq → ($port)"
    ^boxd proxy set-port --vm freeq --port $port
  }

  print "==> done. https://freeq.boxd.sh/chat"
}

# ── helpers ────────────────────────────────────────────────────────────

def find_repo_root [] {
  mut dir = $env.PWD
  loop {
    if (($dir | path join ".jj") | path exists) or (($dir | path join ".git") | path exists) {
      return $dir
    }
    let parent = ($dir | path dirname)
    if $parent == $dir {
      error make {msg: "not inside a jj/git repo"}
    }
    $dir = $parent
  }
}

def jj_has_web4_changes [] {
  let text = (^jj --config "ui.paginate=never" status | complete).stdout
  $text | str contains "freeq-web4/"
}

def rsync_web4 [src: string, dest: string] {
  let args = [
    "-az"
    "--delete"
    "--exclude=build/"
    "--exclude=.dev-data/"
    "--exclude=.git/"
    "--exclude=.jj/"
    "--exclude=*.log"
    "--exclude=erl_crash.dump"
    "--exclude=.env"
    "--exclude=.env.*"
    $"($src)/"
    $dest
  ]
  run-external rsync ...$args
}

def ensure_remote_unit [host: string, remote_dir: string, port: int] {
  let env_body = ([
    $"PORT=($port)"
    "FREEQ_PUBLIC_URL=https://freeq.boxd.sh"
    "FREEQ_UPSTREAM=wss://irc.freeq.at/irc"
    "FREEQ_UPSTREAM_REST=https://irc.freeq.at"
    "FREEQ_WEB4_SESSIONS_DIR=/home/boxd/data/web4-sessions"
    "FREEQ_WEB4_PENDING_OAUTH_DIR=/home/boxd/data/web4-pending-oauth"
    "FREEQ_WEB4_PREVIEW_CACHE_DIR=/home/boxd/data/web4-preview-cache"
    "LANG=C.UTF-8"
    "LC_ALL=C.UTF-8"
    ""
  ] | str join "\n")

  let unit_body = ([
    "[Unit]"
    "Description=freeq-web4 Gleam Lightspeed (nix develop)"
    "After=network-online.target"
    "Wants=network-online.target"
    ""
    "[Service]"
    "Type=simple"
    $"WorkingDirectory=($remote_dir)"
    "EnvironmentFile=/home/boxd/freeq-web4.env"
    "Environment=PATH=/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin"
    "# Flake tools (gleam-preview + erlang) from freeq-web4/flake.nix"
    $"ExecStart=/nix/var/nix/profiles/default/bin/nix develop ($remote_dir) -c gleam run"
    "Restart=on-failure"
    "RestartSec=3"
    "TimeoutStartSec=300"
    ""
    "[Install]"
    "WantedBy=default.target"
    ""
  ] | str join "\n")

  print "==> ensure remote env + systemd user unit + data dirs"
  # Upload via stdin → temp → install (avoids quoting hell for multi-line files).
  let script = ([
    "set -euo pipefail"
    "mkdir -p /home/boxd/data/web4-sessions /home/boxd/data/web4-pending-oauth /home/boxd/data/web4-preview-cache"
    "mkdir -p /home/boxd/.config/systemd/user"
    "cat > /home/boxd/freeq-web4.env <<'ENV_EOF'"
    $env_body
    "ENV_EOF"
    "chmod 600 /home/boxd/freeq-web4.env"
    "cat > /home/boxd/.config/systemd/user/freeq-web4.service <<'UNIT_EOF'"
    $unit_body
    "UNIT_EOF"
    "systemctl --user daemon-reload"
    # Linger so user services survive logout / keep running after reboot
    "loginctl enable-linger boxd 2>/dev/null || true"
  ] | str join "\n")

  $script | ^ssh $host bash -s
}
