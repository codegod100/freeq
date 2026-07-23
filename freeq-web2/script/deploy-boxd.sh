#!/usr/bin/env bash
# Deploy freeq-web2 to freeq.boxd (https://freeq.boxd.sh).
#
# Required after any freeq-web2 change — see AGENTS.md § Deploy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${FREEQ_BOXD_HOST:-freeq.boxd}"
REMOTE_DIR="${FREEQ_BOXD_DIR:-/home/boxd/freeq-web2}"

cd "$ROOT"

echo "==> freeq-web2 → ${HOST}:${REMOTE_DIR}"

# Bundle JS when sources or entrypoint changed (or builds missing).
if [[ ! -f app/assets/builds/application.js ]] ||
   [[ app/javascript -nt app/assets/builds/application.js ]] ||
   [[ package.json -nt app/assets/builds/application.js ]]; then
  echo "==> npm run build"
  if command -v npm >/dev/null 2>&1; then
    npm run build
  else
    echo "npm not on PATH; building on remote after rsync"
  fi
fi

echo "==> rsync (preserve remote .env / sessions / vendor)"
rsync -az --delete \
  --exclude '.env' \
  --exclude '.env.*' \
  --exclude '.dev-data/' \
  --exclude 'log/' \
  --exclude 'tmp/' \
  --exclude 'node_modules/' \
  --exclude 'vendor/bundle/' \
  --exclude '.bundle/' \
  --exclude '.git/' \
  --exclude '.jj/' \
  --exclude 'storage/' \
  --exclude '*.log' \
  ./ "${HOST}:${REMOTE_DIR}/"

echo "==> remote: npm build + assets:precompile + restart"
ssh "$HOST" bash -s <<'REMOTE'
set -euo pipefail
cd /home/boxd/freeq-web2

export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:$PATH"
# Match production service env for bundle path.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

if command -v npm >/dev/null 2>&1; then
  # esbuild is a devDependency — need full install for npm run build.
  if [[ ! -d node_modules/esbuild ]] || [[ package.json -nt node_modules ]]; then
    npm ci 2>/dev/null || npm install
  fi
  npm run build
  npm run build:css
fi

export RAILS_ENV="${RAILS_ENV:-production}"
export BUNDLE_PATH="${BUNDLE_PATH:-vendor/bundle}"
export GEM_HOME="${GEM_HOME:-vendor/bundle/ruby/3.2.0}"
export PATH="${GEM_HOME}/bin:${PATH}"

# Propshaft digests under public/assets (layout uses digested application.js/css).
bundle exec rails assets:precompile
sudo systemctl restart freeq-web2
sleep 2
systemctl is-active freeq-web2
# Quick health: puma listening + My Channels fix present on disk
ss -ltn | grep -q ':3000' && echo "puma :3000 ok" || echo "WARN: nothing on :3000 yet"
grep -q 'track_joined!' lib/session_state.rb && echo "track_joined! ok" || echo "WARN: track_joined! missing"
grep -q 'turbo-prefetch' app/views/layouts/application.html.erb && echo "turbo-prefetch meta ok" || echo "WARN: turbo-prefetch meta missing"
REMOTE

echo "==> done. https://freeq.boxd.sh/chat"
