#!/bin/bash
# Deploy freeq-site to Miren
# Copies docs from repo root before deploying

set -e
cd "$(dirname "$0")"

# Copy docs from parent repo (these get uploaded with the deploy)
rm -rf docs
cp -r ../docs ./docs

# Write git commit hash for the /version endpoint
git -C .. rev-parse --short HEAD 2>/dev/null > .git_commit || echo "unknown" > .git_commit

echo "Deploying freeq-site (commit: $(cat .git_commit))..."
# Pin the target cluster. PRODUCTION is the `freeq` cluster (87.99.152.98) —
# that's where freeq.at / www.freeq.at DNS points and where the freeq-site
# app with the www.freeq.at route lives (`miren app list -C freeq`). A copy
# also exists on BlueYard, but deploying there does NOT update the live site
# (discovered 2026-07-23: a BlueYard-pinned deploy left freeq.at stale).
miren deploy -f -C freeq

echo "Deployed! Docs will be at https://www.freeq.at/docs/"
