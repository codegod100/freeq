#!/usr/bin/env nu
# Deploy freeq-web3 to freeq.boxd (https://freeq.boxd.sh).
#
# Flow (default):
#   1. Commit dirty freeq-web3 changes with jj (if any)
#   2. Push `main` to origin (GitHub)
#   3. On the VM: git fetch + reset to origin/main, compile, restart
#
# Can the VM "pull from my laptop"?
#   Not really. freeq.boxd cannot open a connection back to your machine
#   (NAT / no git server on the laptop). The durable path is:
#
#     laptop  --jj push-->  GitHub  --git pull-->  freeq.boxd
#
#   For a direct laptop → VM copy (no GitHub), pass --rsync.
#
# Usage:
#   nu freeq-web3/script/deploy-boxd.nu
#   nu freeq-web3/script/deploy-boxd.nu -m "Fix image previews"
#   nu freeq-web3/script/deploy-boxd.nu --rsync
#   nu freeq-web3/script/deploy-boxd.nu --no-commit
#   nu freeq-web3/script/deploy-boxd.nu --skip-restart

def main [
  --message (-m): string = ""          # commit message (prompted if empty + dirty)
  --no-commit                          # skip jj commit even if dirty
  --no-push                            # skip jj git push
  --rsync                              # rsync tree to VM instead of git pull
  --host: string = "freeq.boxd"        # SSH host (boxd ssh-config alias)
  --remote-dir: string = "/home/boxd/freeq"
  --web3-rel: string = "freeq-web3"    # path under remote-dir
  --skip-build                         # skip mix compile / assets.deploy
  --skip-restart                       # skip systemctl restart
] {
  let root = (find_repo_root)
  let web3 = ($root | path join "freeq-web3")
  if not ($web3 | path exists) {
    error make {msg: $"freeq-web3 not found under ($root)"}
  }

  print $"==> repo: ($root)"
  cd $root

  # ── 1. Commit (jj) ─────────────────────────────────────────────────
  if not $no_commit {
    if (jj_has_web3_changes) {
      mut msg = $message
      if ($msg | str trim | is-empty) {
        $msg = (input "commit message: ")
      }
      if ($msg | str trim | is-empty) {
        error make {msg: "empty commit message; aborting"}
      }
      print $"==> jj commit: ($msg)"
      ^jj --config "ui.paginate=never" commit -m $msg
      # Point main at the new commit (@- after commit)
      ^jj --config "ui.paginate=never" bookmark set main -r "@-"
    } else {
      print "==> working tree clean for freeq-web3 (no commit)"
    }
  } else {
    print "==> --no-commit: leaving local history alone"
  }

  # ── 2. Push or rsync ───────────────────────────────────────────────
  if $rsync {
    print $"==> rsync freeq-web3 → ($host):($remote_dir)/($web3_rel)/"
    rsync_web3 $web3 $"($host):($remote_dir)/($web3_rel)/"
  } else {
    if not $no_push {
      print "==> jj git push --bookmark main"
      ^jj --config "ui.paginate=never" git push --bookmark main
    } else {
      print "==> --no-push: skipping push (origin must already have the commit)"
    }

    print $"==> ($host): git fetch + reset to origin/main"
    # Deploy tree is disposable: hard-reset so prior rsync dirt doesn't block pull.
    let pull_script = (
      [
        "set -euo pipefail"
        $"cd ($remote_dir)"
        "git fetch origin main"
        "git reset --hard origin/main"
        "git status -sb"
        "git log -1 --oneline"
      ] | str join "\n"
    )
    ^ssh $host bash -lc $pull_script
  }

  # ── 3. Build + restart on VM ───────────────────────────────────────
  let remote_web3 = $"($remote_dir)/($web3_rel)"
  let do_build = (not $skip_build)
  let do_restart = (not $skip_restart)

  mut lines = [
    "set -euo pipefail"
    $"cd ($remote_web3)"
    # $PATH must stay literal for the remote shell — single-quoted fragment
    'export PATH="/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:$PATH"'
    "export MIX_HOME=/home/boxd/freeq-web3/.mix"
    "export HEX_HOME=/home/boxd/freeq-web3/.hex"
    "set -a"
    "source /home/boxd/freeq-web3.env"
    "set +a"
  ]

  if $do_build {
    $lines = (
      $lines | append [
        "echo '==> mix deps.get + compile + assets.deploy'"
        $"nix develop ($remote_web3) -c bash -lc 'set -euo pipefail; mix deps.get; mix compile; mix assets.deploy'"
      ]
    )
  }

  if $do_restart {
    $lines = (
      $lines | append [
        "echo '==> systemctl --user restart freeq-web3'"
        "systemctl --user restart freeq-web3.service"
        'for i in $(seq 1 20); do if systemctl --user is-active freeq-web3.service >/dev/null 2>&1 && ss -ltn | grep -qE ":3000\b"; then break; fi; sleep 1; done'
        "systemctl --user is-active freeq-web3.service"
        'ss -ltn | grep -E ":3000\b" || echo "WARN: nothing on :3000 yet"'
        'curl -sS -o /dev/null -w "local_http=%{http_code}\n" --max-time 10 http://127.0.0.1:3000/chat || true'
      ]
    )
  }

  let remote = ($lines | str join "\n")
  print $"==> ($host): build/restart freeq-web3"
  ^ssh $host bash -lc $remote

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

def jj_has_web3_changes [] {
  let text = (^jj --config "ui.paginate=never" status | complete).stdout
  $text | str contains "freeq-web3/"
}

def rsync_web3 [src: string, dest: string] {
  let args = [
    "-az"
    "--delete"
    "--exclude=_build/"
    "--exclude=deps/"
    "--exclude=.mix/"
    "--exclude=.hex/"
    "--exclude=node_modules/"
    "--exclude=assets/node_modules/"
    "--exclude=.dev-data/"
    "--exclude=.git/"
    "--exclude=.jj/"
    "--exclude=*.log"
    "--exclude=erl_crash.dump"
    "--exclude=priv/static/assets/"
    "--exclude=priv/static/cache_manifest.json"
    $"($src)/"
    $dest
  ]
  run-external rsync ...$args
}
