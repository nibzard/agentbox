#!/usr/bin/env bash
# ABOUTME: End-to-end test: run agentbox.sh on a Steel computer, then run agentbox-verify on the box.
# ABOUTME: Runs the script twice to prove idempotency. Needs STEEL_API_KEY and the steel CLI.
#
# usage:
#   tests/e2e.sh                       # create a box, test, delete it
#   KEEP=1 tests/e2e.sh                # leave the box running after the test
#   COMPUTER_ID=cmp_... tests/e2e.sh   # test an existing box (never deleted)
#   AGENTBOX_ARGS="--lean" tests/e2e.sh
set -euo pipefail

cd "$(dirname "$0")/.."
: "${STEEL_API_KEY:?export STEEL_API_KEY first}"
command -v steel >/dev/null || { echo "steel CLI not found (export PATH=\"\$HOME/.steel/bin:\$PATH\")" >&2; exit 2; }

AGENTBOX_ARGS="${AGENTBOX_ARGS:-}"
CREATED=0
if [[ -z "${COMPUTER_ID:-}" ]]; then
  echo "==> creating a Steel computer"
  COMPUTER_ID=$(steel computer create --wait --timeout 1800 --json | jq -r '.data.id')
  CREATED=1
fi
echo "==> box: $COMPUTER_ID"

cleanup() {
  if (( CREATED )) && [[ "${KEEP:-0}" != 1 ]]; then
    echo "==> deleting $COMPUTER_ID"
    steel computer delete "$COMPUTER_ID" >/dev/null
  else
    echo "==> keeping $COMPUTER_ID (steel computer ssh $COMPUTER_ID)"
  fi
}
trap cleanup EXIT

# The box has no curl yet, so the script goes in over ssh. Root is the ssh user.
run_script() {
  # shellcheck disable=SC2086
  steel computer ssh "$COMPUTER_ID" -- bash -s -- $AGENTBOX_ARGS < agentbox.sh
}

echo "==> first run"
run_script
echo "==> second run (idempotency)"
run_script

# exec returns the remote exit code, so a failing check fails this script.
echo "==> agentbox-verify"
steel computer exec "$COMPUTER_ID" --timeout 300 -c 'agentbox-verify'
echo "==> e2e passed"
