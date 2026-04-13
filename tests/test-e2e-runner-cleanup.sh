#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
run_id="cleanup-probe-$$"
run_tmpdir="/tmp/$run_id"
runner="$repo_root/scripts/run-e2e-test.sh"
test_script="$repo_root/tests/e2e/detached_process_leak.lua"
log_path="$run_tmpdir/runner.log"
pid_path="$run_tmpdir/detached-child.pid"
child_pid=""

rm -rf -- "$run_tmpdir"
mkdir -p "$run_tmpdir"

cleanup_probe() {
  if [[ -n "$child_pid" ]]; then
    kill "$child_pid" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$child_pid" >/dev/null 2>&1 || true
  fi
}

trap cleanup_probe EXIT

set +e
ARK_TEST_RUN_ID="$run_id" \
ARK_TEST_TMPDIR="$run_tmpdir" \
"$runner" --timeout 3 --kill-after 1 --keep-artifacts "$test_script" \
  >"$log_path" 2>&1
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  echo "expected runner timeout for cleanup probe" >&2
  exit 1
fi

if [[ ! -f "$pid_path" ]]; then
  echo "cleanup probe did not record detached child pid" >&2
  cat "$log_path" >&2 || true
  exit 1
fi

child_pid=$(tr -d '[:space:]' <"$pid_path")
if [[ -z "$child_pid" ]]; then
  echo "cleanup probe recorded empty child pid" >&2
  exit 1
fi

if kill -0 "$child_pid" >/dev/null 2>&1; then
  echo "detached child still alive after runner cleanup: $child_pid" >&2
  ps -fp "$child_pid" >&2 || true
  exit 1
fi

tmux_socket="$run_tmpdir/tmux.sock"
if command -v tmux >/dev/null 2>&1; then
  if tmux -S "$tmux_socket" ls -F '#{session_name}' 2>/dev/null | awk -v prefix="arktest_${run_id}_" 'index($0, prefix) == 1 { found = 1 } END { exit found ? 0 : 1 }'; then
    echo "runner left arktest tmux sessions behind for $run_id" >&2
    tmux -S "$tmux_socket" ls >&2 || true
    exit 1
  fi
fi

rm -rf -- "$run_tmpdir"
