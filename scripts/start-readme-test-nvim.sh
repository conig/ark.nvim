#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/start-readme-test-nvim.sh [options] [-- <nvim args...>]

Options:
  --direct                 Run directly instead of creating/attaching a tmux session
  --tmux-session <name>    Session name to use when outside tmux
  --help                   Show this message

This starts Neovim with the isolated README-minimal config at:
  testing/readme-minimal/init.lua

When run outside tmux, it creates or attaches to a dedicated tmux session so
the config can exercise the recommended managed-pane workflow.
EOF
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root="$repo_root/testing/readme-minimal"
init_path="$test_root/init.lua"
data_home="$test_root/data"
state_home="$test_root/state"
cache_home="$test_root/cache"
tmux_session="ark-readme-test"
direct=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --direct)
      direct=1
      shift
      ;;
    --tmux-session)
      tmux_session="${2:?missing value for --tmux-session}"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

mkdir -p "$data_home/nvim/lazy" "$state_home" "$cache_home"

local_lazy="$data_home/nvim/lazy/lazy.nvim"
if [[ -L "$local_lazy" ]]; then
  rm -f "$local_lazy"
fi

cmd=(
  env
  XDG_DATA_HOME="$data_home"
  XDG_STATE_HOME="$state_home"
  XDG_CACHE_HOME="$cache_home"
  nvim
  -u "$init_path"
)
cmd+=("$@")

if [[ -n "${TMUX:-}" || "$direct" -eq 1 ]]; then
  exec "${cmd[@]}"
fi

printf -v quoted_cmd '%q ' "${cmd[@]}"
printf -v quoted_repo '%q' "$repo_root"
exec tmux new-session -A -s "$tmux_session" "cd $quoted_repo && $quoted_cmd"
