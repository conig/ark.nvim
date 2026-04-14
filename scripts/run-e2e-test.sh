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
  --cwd <path>              Working directory to launch Neovim from
  --open-r-buffer <name>    Create and open a scratch .R file under the run tmpdir
  --keep-artifacts          Keep the run tmpdir on success
  --help                    Show this message

Environment exported to the test:
  ARK_TEST_RUN_ID
  ARK_TEST_TMPDIR
  ARK_TEST_TMUX_MANIFEST
  ARK_TEST_NVIM_INIT
  ARK_REPO_ROOT
  XDG_STATE_HOME
EOF
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
init_mode="NONE"
timeout_secs=120
kill_after_secs=10
open_r_buffer=""
keep_artifacts=0
test_data_home="${ARK_TEST_DATA_HOME:-/tmp/arktest-data}"
run_cwd=""

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
    --cwd)
      run_cwd="${2:?missing value for --cwd}"
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

if [[ "$test_script" != /* ]]; then
  test_script="$(cd -- "$(dirname -- "$test_script")" && pwd)/$(basename -- "$test_script")"
fi

run_id="${ARK_TEST_RUN_ID:-arktest-$(date +%s)-$$}"
run_id="${run_id//[^[:alnum:]_-]/_}"
run_tmpdir="${ARK_TEST_TMPDIR:-/tmp/$run_id}"
state_home="$run_tmpdir/state"
manifest="$run_tmpdir/tmux-sessions.txt"
log_path="$run_tmpdir/nvim.log"
tmux_socket="$run_tmpdir/tmux.sock"
tmux_server_session="arktest_${run_id}_anchor"
tmux_anchor_pane=""
tmux_anchor_session=""

mkdir -p "$run_tmpdir" "$state_home"
: >"$manifest"

if [[ "$init_mode" == "NONE" ]]; then
  init_arg="NONE"
else
  init_arg="$init_mode"
  if [[ ! -f "$init_arg" && -f "$repo_root/$init_arg" ]]; then
    init_arg="$repo_root/$init_arg"
  fi
  if [[ ! -f "$init_arg" ]]; then
    echo "Init script not found: $init_mode" >&2
    exit 2
  fi
  init_arg="$(cd -- "$(dirname -- "$init_arg")" && pwd)/$(basename -- "$init_arg")"
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

if [[ -n "$run_cwd" && ! -d "$run_cwd" && -d "$repo_root/$run_cwd" ]]; then
  run_cwd="$repo_root/$run_cwd"
fi

if [[ -n "$run_cwd" && ! -d "$run_cwd" ]]; then
  echo "Working directory not found: $run_cwd" >&2
  exit 2
fi

tmux_cmd() {
  tmux -S "$tmux_socket" "$@"
}

ensure_test_blink_plugin() {
  local test_blink_root="${test_data_home}/nvim/lazy/blink.cmp"
  local default_blink_root="${HOME}/.local/share/nvim/lazy/blink.cmp"
  local source_blink_root="${ARK_TEST_BLINK_ROOT:-$default_blink_root}"

  if [[ -e "$test_blink_root" || ! -d "$source_blink_root" ]]; then
    return 0
  fi

  mkdir -p -- "$(dirname -- "$test_blink_root")"
  ln -s -- "$source_blink_root" "$test_blink_root"
}

setup_tmux_server() {
  local output=""
  output="$(tmux_cmd new-session -d -P -F '#{pane_id}
#{session_name}' -s "$tmux_server_session")"
  if [[ -z "$output" ]]; then
    echo "failed to create dedicated tmux server session" >&2
    exit 1
  fi

  tmux_anchor_pane="$(printf '%s\n' "$output" | sed -n '1p')"
  tmux_anchor_session="$(printf '%s\n' "$output" | sed -n '2p')"
  if [[ -z "$tmux_anchor_pane" || -z "$tmux_anchor_session" ]]; then
    echo "failed to parse dedicated tmux server identifiers: $output" >&2
    exit 1
  fi

  printf '%s\n' "$tmux_anchor_session" >>"$manifest"
}

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
      tmux_cmd kill-session -t "$session_name" >/dev/null 2>&1 || true
    done <"$manifest"
  fi

  if command -v tmux >/dev/null 2>&1; then
    while IFS= read -r session_name; do
      [[ -z "$session_name" ]] && continue
      tmux_cmd kill-session -t "$session_name" >/dev/null 2>&1 || true
    done < <(tmux_cmd ls -F '#{session_name}' 2>/dev/null | awk -v prefix="arktest_${run_id}_" 'index($0, prefix) == 1 { print $0 }')
  fi

  tmux_cmd kill-server >/dev/null 2>&1 || true

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

setup_tmux_server
ensure_test_blink_plugin

if [[ -n "$run_cwd" ]]; then
  cd -- "$run_cwd"
fi

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
  -c "lua local function cleanup_ark() local ok, ark = pcall(require, 'ark'); if ok and type(ark.stop_pane) == 'function' then pcall(ark.stop_pane) end end; local function run_test() local ok, err = xpcall(function() dofile([[$test_script]]) end, debug.traceback); cleanup_ark(); if not ok then vim.api.nvim_err_writeln(err); vim.cmd('cquit 1'); return end; vim.cmd('qa!') end; if vim.v.vim_did_enter == 1 then run_test() else vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = run_test }) end"
)

env \
  ARK_TEST_RUN_ID="$run_id" \
  ARK_TEST_TMPDIR="$run_tmpdir" \
  ARK_TEST_TMUX_MANIFEST="$manifest" \
  ARK_TEST_NVIM_INIT="$init_arg" \
  ARK_TUI_TRACE_LOG="$run_tmpdir/trace.log" \
  ARK_REPO_ROOT="$repo_root" \
  ARK_TMUX_SOCKET="$tmux_socket" \
  ARK_TMUX_SESSION="$tmux_anchor_session" \
  ARK_TMUX_ANCHOR_PANE="$tmux_anchor_pane" \
  TMUX="" \
  TMUX_PANE="" \
  XDG_DATA_HOME="$test_data_home" \
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
