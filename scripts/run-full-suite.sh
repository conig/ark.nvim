#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/run-full-suite.sh [options]

Options:
  --skip-rust             Skip cargo nextest
  --skip-clippy           Skip cargo clippy
  --skip-e2e              Skip Neovim E2E tests
  --tier <name>           Test tier: required, unit, fast, serial-integration,
                          full-tui, performance, soak, integration, or full
                          Default: full
  --filter <substring>    Only run E2E tests whose basename contains the substring
  --init <path>           Override the manifest init for full-TUI E2Es
  --open-r-buffer <name>  Scratch .R file to open when requested by the manifest
                          Default: smoke.R
  --e2e-timeout <secs>    Per-test timeout passed to run-e2e-test.sh
                          Default: 120
  --keep-artifacts        Keep E2E artifacts on success
  --list-e2e              Print the E2E tests this wrapper would run, then exit
  --help                  Show this message

This wrapper is the canonical full-confidence verification path. It runs:
  1. cargo nextest
  2. cargo clippy
  3. cargo build -p ark-lsp
  4. serial Neovim E2Es via scripts/run-e2e-test.sh
EOF
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest_resolver="$repo_root/scripts/test-manifest.py"
init_override=""
open_r_buffer="smoke.R"
test_tier="full"
e2e_timeout=120
keep_artifacts=0
skip_rust=0
skip_clippy=0
skip_e2e=0
list_e2e=0
filter=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-rust)
      skip_rust=1
      shift
      ;;
    --skip-clippy)
      skip_clippy=1
      shift
      ;;
    --skip-e2e)
      skip_e2e=1
      shift
      ;;
    --tier)
      test_tier="${2:?missing value for --tier}"
      shift 2
      ;;
    --filter)
      filter="${2:?missing value for --filter}"
      shift 2
      ;;
    --init)
      init_override="${2:?missing value for --init}"
      shift 2
      ;;
    --open-r-buffer)
      open_r_buffer="${2:?missing value for --open-r-buffer}"
      shift 2
      ;;
    --e2e-timeout)
      e2e_timeout="${2:?missing value for --e2e-timeout}"
      shift 2
      ;;
    --keep-artifacts)
      keep_artifacts=1
      shift
      ;;
    --list-e2e)
      list_e2e=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

declare -a failures=()
declare -a e2e_tests=()
declare -a e2e_tiers=()
declare -a e2e_inits=()
declare -a e2e_open_buffers=()
declare -a e2e_cwds=()
declare -a e2e_contracts=()
declare -a e2e_dependencies=()

build_e2e_list() {
  local tier=""
  local init=""
  local open_buffer=""
  local cwd=""
  local contract=""
  local dependencies=""
  local test_name=""

  while IFS=$'\t' read -r test_path tier init open_buffer cwd contract dependencies; do
    test_name=$(basename -- "$test_path")
    if [[ -n "$filter" && "$test_name" != *"$filter"* ]]; then
      continue
    fi

    e2e_tests+=("$test_path")
    e2e_tiers+=("$tier")
    e2e_inits+=("$init")
    e2e_open_buffers+=("$open_buffer")
    e2e_cwds+=("$cwd")
    e2e_contracts+=("$contract")
    e2e_dependencies+=("$dependencies")
  done < <(python3 "$manifest_resolver" list --tier "$test_tier" --format tsv)
}

run_step() {
  local label="$1"
  shift
  local status=0

  printf '\n==> %s\n' "$label"
  "$@"
  status=$?

  if [[ "$status" -eq 0 ]]; then
    printf 'PASS: %s\n' "$label"
    return 0
  fi

  printf 'FAIL: %s (exit %s)\n' "$label" "$status" >&2
  failures+=("$label")
  return "$status"
}

run_e2e_test() {
  local index="$1"
  local test_path="${e2e_tests[$index]}"
  local test_name
  local tier="${e2e_tiers[$index]}"
  local manifest_init="${e2e_inits[$index]}"
  local needs_open_r_buffer="${e2e_open_buffers[$index]}"
  local run_cwd="${e2e_cwds[$index]}"
  local contract="${e2e_contracts[$index]}"
  local dependencies="${e2e_dependencies[$index]}"
  local -a cmd

  test_name=$(basename -- "$test_path")
  cmd=("$repo_root/scripts/run-e2e-test.sh" "--timeout" "$e2e_timeout")

  if [[ "$keep_artifacts" -eq 1 ]]; then
    cmd+=("--keep-artifacts")
  fi

  if [[ ",$dependencies," != *,tmux,* ]]; then
    cmd+=("--no-tmux")
  fi

  if [[ "$manifest_init" != "NONE" ]]; then
    if [[ -n "$init_override" ]]; then
      cmd+=("--init" "$init_override")
    else
      cmd+=("--init" "$manifest_init")
    fi
  fi

  if [[ "$needs_open_r_buffer" -eq 1 ]]; then
    cmd+=("--open-r-buffer" "$open_r_buffer")
  fi

  if [[ "$run_cwd" == "HOME" ]]; then
    cmd+=("--cwd" "$HOME")
  elif [[ "$run_cwd" != "-" ]]; then
    cmd+=("--cwd" "$run_cwd")
  fi

  cmd+=("$test_path")
  printf 'Contract: %s\n' "$contract"
  run_step "e2e:$tier:$test_name" "${cmd[@]}"
}

build_e2e_list

if [[ "$list_e2e" -eq 1 ]]; then
  printf '%s\n' "${e2e_tests[@]}"
  exit 0
fi

run_step "test manifest" python3 "$manifest_resolver" validate

if [[ "$skip_rust" -eq 0 ]]; then
  run_step "cargo nextest" cargo nextest run --no-fail-fast
fi

if [[ "$skip_clippy" -eq 0 ]]; then
  run_step "cargo clippy" cargo clippy --workspace --all-targets --all-features -- -D warnings
fi

build_ok=1
if [[ "$skip_e2e" -eq 0 ]]; then
  if [[ "${#e2e_tests[@]}" -eq 0 ]]; then
    echo "No E2E tests matched the current selection." >&2
    exit 2
  fi

  if ! run_step "cargo build ark-lsp" cargo build -p ark-lsp; then
    build_ok=0
  fi

  if [[ "$build_ok" -eq 1 ]]; then
    for index in "${!e2e_tests[@]}"; do
      run_e2e_test "$index"
    done
    if [[ -z "$filter" && "$test_tier" == "full" ]]; then
      run_step "e2e-runner cleanup" "$repo_root/tests/test-e2e-runner-cleanup.sh"
    fi
  else
    failures+=("e2e:skipped-after-build-failure")
    echo "Skipping E2Es because ark-lsp failed to build." >&2
  fi
fi

printf '\n==> Summary\n'
if [[ "${#failures[@]}" -eq 0 ]]; then
  echo "PASS: full suite completed without failures"
  exit 0
fi

printf 'FAIL: %s step(s) failed\n' "${#failures[@]}" >&2
printf ' - %s\n' "${failures[@]}" >&2
exit 1
