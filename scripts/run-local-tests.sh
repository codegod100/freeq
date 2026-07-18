#!/usr/bin/env bash
#
# Run acceptance tests against locally-running test servers.
#
# Prerequisites: ./scripts/start-test-servers.sh must be running in another terminal.
#
# Usage:
#   ./scripts/run-local-tests.sh                    # all tests
#   ./scripts/run-local-tests.sh single             # single-server tests only
#   ./scripts/run-local-tests.sh s2s                # S2S tests only
#   ./scripts/run-local-tests.sh inv                # all INV tests
#   ./scripts/run-local-tests.sh s2s_inv10          # specific test
#   ./scripts/run-local-tests.sh s2s_inv10 s2s_inv2 # multiple tests

set -euo pipefail
cd "$(dirname "$0")/.."

PORT_A=16667
PORT_B=16668

# Verify servers are running
for port in $PORT_A $PORT_B; do
    if ! nc -z 127.0.0.1 "$port" 2>/dev/null; then
        echo "ERROR: No server on port $port"
        echo ""
        echo "Start test servers first:"
        echo "  ./scripts/start-test-servers.sh"
        exit 1
    fi
done

export SERVER="127.0.0.1:$PORT_A"
export LOCAL_SERVER="127.0.0.1:$PORT_A"
export REMOTE_SERVER="127.0.0.1:$PORT_B"

MODE="${1:-all}"
shift 2>/dev/null || true

case "$MODE" in
    all)
        echo "▶ Running S2S tests first: $LOCAL_SERVER ↔ $REMOTE_SERVER"
        echo ""
        cargo test -p freeq-server --test s2s_acceptance -- \
            --nocapture --test-threads=1 s2s_
        S2S_EXIT=$?

        # Restart servers between suites — the S2S suite creates many channels
        # and connections which can exhaust the server's event loop.
        echo ""
        echo "▶ Restarting servers for single-server tests..."
        "$(dirname "$0")/start-test-servers.sh" stop 2>/dev/null
        sleep 2
        # start-test-servers.sh blocks, so run in background
        "$(dirname "$0")/start-test-servers.sh" > /dev/null 2>&1 &
        # Wait for servers to be ready
        for i in $(seq 1 120); do
            if nc -z 127.0.0.1 "$PORT_A" 2>/dev/null && nc -z 127.0.0.1 "$PORT_B" 2>/dev/null; then
                sleep 3  # extra settle time for S2S link
                break
            fi
            sleep 1
        done

        echo "▶ Running single-server tests against $SERVER"
        echo ""
        cargo test -p freeq-server --test s2s_acceptance -- \
            --nocapture --test-threads=1 single_server
        SS_EXIT=$?

        if [ $S2S_EXIT -ne 0 ] || [ $SS_EXIT -ne 0 ]; then
            echo ""
            echo "⚠ Some tests failed (S2S exit=$S2S_EXIT, single_server exit=$SS_EXIT)"
            exit 1
        fi
        ;;
    single|single_server)
        echo "▶ Running single-server tests against $SERVER"
        cargo test -p freeq-server --test s2s_acceptance -- \
            --nocapture --test-threads=1 single_server
        ;;
    s2s|federation)
        echo "▶ Running S2S tests: $LOCAL_SERVER ↔ $REMOTE_SERVER"
        cargo test -p freeq-server --test s2s_acceptance -- \
            --nocapture --test-threads=1 s2s_
        ;;
    inv)
        echo "▶ Running all INV tests"
        cargo test -p freeq-server --test s2s_acceptance -- \
            --nocapture --test-threads=1 inv
        ;;
    *)
        # Run specific test(s) — pass all remaining args as test filters
        FILTERS="$MODE $*"
        echo "▶ Running test(s): $FILTERS"
        for filter in $FILTERS; do
            cargo test -p freeq-server --test s2s_acceptance -- \
                --nocapture --test-threads=1 "$filter"
        done
        ;;
esac
