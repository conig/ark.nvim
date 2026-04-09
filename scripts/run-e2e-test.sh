#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/run-e2e-test.sh [options] <test.lua> [-- <nvim args...>]

Options:
  --init <path|NONE>        Neovim init to use. Default: NONE
  --timeout <seconds>       Hard timeout for the whole test. Default: 120
  --kill-after <seconds>    Extra grace after timeout before SIGKILL. Default: 10
  --open-r-buffer <name>    Create and open a scratch .R file under the run tmpdir
  --keep-artifacts          Keep the run tmpdir on success
  --help                    Show this message

Environment exported to the test:
  ARK_TEST_RUN_ID
  ARK_TEST_TMPDIR
  ARK_TEST_TMUX_MANIFEST
  XDG_STATE_HOME
EOF
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
init_mode="NONE"
timeout_secs=120
kill_after_secs=10
open_r_buffer=""
keep_artifacts=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init)
      init_mode="${2:?missing value for --init}"
      shift 2
      ;;
    --timeout)
      timeout_secs="${2:?missing value for --timeout}"
      shift 2
      ;;
    --kill-after)
      kill_after_secs="${2:?missing value for --kill-after}"
      shift 2
      ;;
    --open-r-buffer)
      open_r_buffer="${2:?missing value for --open-r-buffer}"
      shift 2
      ;;
    --keep-artifacts)
      keep_artifacts=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

test_script="$1"
shift

if [[ ! -f "$test_script" ]]; then
  if [[ -f "$repo_root/$test_script" ]]; then
    test_script="$repo_root/$test_script"
  else
    echo "Test script not found: $test_script" >&2
    exit 2
  fi
fi

run_id="${ARK_TEST_RUN_ID:-arktest-$(date +%s)-$$}"
run_id="${run_id//[^[:alnum:]_-]/_}"
run_tmpdir="${ARK_TEST_TMPDIR:-/tmp/$run_id}"
state_home="$run_tmpdir/state"
manifest="$run_tmpdir/tmux-sessions.txt"
log_path="$run_tmpdir/nvim.log"

mkdir -p "$run_tmpdir" "$state_home"
: >"$manifest"

if [[ "$init_mode" == "NONE" ]]; then
  init_arg="NONE"
else
  init_arg="$init_mode"
fi

nvim_args=()
if [[ -n "$open_r_buffer" ]]; then
  mkdir -p "$(dirname -- "$run_tmpdir/$open_r_buffer")"
  : >"$run_tmpdir/$open_r_buffer"
  nvim_args+=("$run_tmpdir/$open_r_buffer")
fi

if [[ $# -gt 0 ]]; then
  nvim_args+=("$@")
fi

run_tagged_pids() {
  local env_path pid env_blob

  for env_path in /proc/[0-9]*/environ; do
    [[ -r "$env_path" ]] || continue

    pid="${env_path#/proc/}"
    pid="${pid%/environ}"

    case "$pid" in
      ''|*[!0-9]*)
        continue
        ;;
    esac

    [[ "$pid" -eq "$$" ]] && continue
    [[ -n "${runner_pid:-}" && "$pid" -eq "$runner_pid" ]] && continue

    env_blob="$(cat "$env_path" 2>/dev/null | tr '\0' '\n' || true)"
    [[ -z "$env_blob" ]] && continue

    if [[ "$env_blob" == *"ARK_TEST_RUN_ID=$run_id"* && "$env_blob" == *"ARK_TEST_TMPDIR=$run_tmpdir"* ]]; then
      printf '%s\n' "$pid"
    fi
  done | sort -u
}

kill_run_tagged_processes() {
  local signal="$1"
  local pid

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    kill "-$signal" "$pid" >/dev/null 2>&1 || true
  done < <(run_tagged_pids)
}

cleanup() {
  local exit_code="${1:-$?}"

  if [[ -f "$manifest" ]]; then
    while IFS= read -r session_name; do
      [[ -z "$session_name" ]] && continue
      tmux kill-session -t "$session_name" >/dev/null 2>&1 || true
    done <"$manifest"
  fi

  if command -v tmux >/dev/null 2>&1; then
    while IFS= read -r session_name; do
      [[ -z "$session_name" ]] && continue
      tmux kill-session -t "$session_name" >/dev/null 2>&1 || true
    done < <(tmux ls -F '#{session_name}' 2>/dev/null | awk -v prefix="arktest_${run_id}_" 'index($0, prefix) == 1 { print $0 }')
  fi

  if [[ -n "${runner_pgid:-}" ]]; then
    kill -- "-$runner_pgid" >/dev/null 2>&1 || true
    sleep 1
    kill -9 -- "-$runner_pgid" >/dev/null 2>&1 || true
  fi

  # Detached children can escape the runner process group, so reap only
  # processes tagged with this run's env to keep parallel runs isolated.
  kill_run_tagged_processes TERM
  sleep 1
  kill_run_tagged_processes KILL

  if [[ "$exit_code" -eq 0 && "$keep_artifacts" -eq 0 ]]; then
    rm -rf -- "$run_tmpdir"
  else
    echo "ark e2e artifacts: $run_tmpdir" >&2
    echo "ark e2e log: $log_path" >&2
  fi

  exit "$exit_code"
}

trap 'cleanup $?' EXIT INT TERM

cmd=(
  nvim
  --headless
  -u "$init_arg"
  -i NONE
  -n
)
cmd+=("${nvim_args[@]}")
cmd+=(
  -c "set shadafile=NONE"
  -c "set rtp^=$repo_root"
  -c "lua package.path = package.path .. ';$repo_root/tests/e2e/?.lua'"
  -c "lua local ok, err = xpcall(function() dofile([[$test_script]]) end, debug.traceback); if not ok then vim.api.nvim_err_writeln(err); vim.cmd('cquit 1') end"
  -c "qa!"
)

env \
  ARK_TEST_RUN_ID="$run_id" \
  ARK_TEST_TMPDIR="$run_tmpdir" \
  ARK_TEST_TMUX_MANIFEST="$manifest" \
  ARK_TUI_TRACE_LOG="$run_tmpdir/trace.log" \
  XDG_STATE_HOME="$state_home" \
  setsid \
  timeout --foreground --kill-after="${kill_after_secs}s" "${timeout_secs}s" "${cmd[@]}" \
  >"$log_path" 2>&1 &
runner_pid=$!
runner_pgid=$(ps -o pgid= "$runner_pid" 2>/dev/null | tr -d ' ' || true)

set +e
wait "$runner_pid"
status=$?
set -e

if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
  echo "ark e2e runner timed out after ${timeout_secs}s: $test_script" >&2
fi

if [[ "$status" -ne 0 ]]; then
  cat "$log_path" >&2 || true
fi

exit "$status"
