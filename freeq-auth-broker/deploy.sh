#!/bin/bash
# Deploy freeq-auth-broker to Miren
set -e
cd "$(dirname "$0")"

HASH=$(git -C .. rev-parse --short HEAD 2>/dev/null || echo unknown)
echo "$HASH" > git_commit.txt

echo "Deploying freeq-auth-broker (commit: $HASH)..."
miren deploy -f -e "GIT_HASH=$HASH"
