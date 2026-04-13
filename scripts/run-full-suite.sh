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
  --filter <substring>    Only run E2E tests whose basename contains the substring
  --init <path>           Init file for full_config_* E2Es
                          Default: tests/e2e/init.lua
  --open-r-buffer <name>  Scratch .R file to open for full_config_* E2Es
                          Default: smoke.R
  --e2e-timeout <secs>    Per-test timeout passed to run-e2e-test.sh
                          Default: 120
  --keep-artifacts        Keep E2E artifacts on success
  --list-e2e              Print the E2E tests this wrapper would run, then exit
  --help                  Show this message

This wrapper is the canonical full-confidence verification path. It runs:
  1. cargo nextest
  2. cargo clippy
  3. cargo build -p ark --bin ark-lsp
  4. serial Neovim E2Es via scripts/run-e2e-test.sh
EOF
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
real_init="$repo_root/tests/e2e/init.lua"
open_r_buffer="smoke.R"
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
    --filter)
      filter="${2:?missing value for --filter}"
      shift 2
      ;;
    --init)
      real_init="${2:?missing value for --init}"
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

build_e2e_list() {
  local test_path=""
  local test_name=""

  while IFS= read -r test_path; do
    test_name=$(basename -- "$test_path")
    case "$test_name" in
      ark_test.lua|tui_blink_trace.lua)
        continue
        ;;
    esac

    if [[ -n "$filter" && "$test_name" != *"$filter"* ]]; then
      continue
    fi

    e2e_tests+=("$test_path")
  done < <(find "$repo_root/tests/e2e" -maxdepth 1 -type f -name '*.lua' | sort)
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
  local test_path="$1"
  local test_name
  local needs_real_init=0
  local needs_open_r_buffer=0
  local requires_blink=0
  local -a cmd

  test_name=$(basename -- "$test_path")
  cmd=("$repo_root/scripts/run-e2e-test.sh" "--timeout" "$e2e_timeout")

  if grep -q 'blink.cmp is required for this test' "$test_path"; then
    requires_blink=1
  fi

  if [[ "$keep_artifacts" -eq 1 ]]; then
    cmd+=("--keep-artifacts")
  fi

  if [[ "$test_name" == full_config_* ]]; then
    needs_real_init=1
    needs_open_r_buffer=1
  elif [[ "$requires_blink" -eq 1 ]]; then
    needs_real_init=1
    needs_open_r_buffer=1
  fi

  if [[ "$needs_real_init" -eq 1 ]]; then
    cmd+=("--init" "$real_init")
  fi

  if [[ "$needs_open_r_buffer" -eq 1 ]]; then
    cmd+=("--open-r-buffer" "$open_r_buffer")
  fi

  cmd+=("$test_path")
  run_step "e2e:$test_name" "${cmd[@]}"
}

build_e2e_list

if [[ "$list_e2e" -eq 1 ]]; then
  printf '%s\n' "${e2e_tests[@]}"
  exit 0
fi

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

  if ! run_step "cargo build ark-lsp" cargo build -p ark --bin ark-lsp; then
    build_ok=0
  fi

  if [[ "$build_ok" -eq 1 ]]; then
    for test_path in "${e2e_tests[@]}"; do
      run_e2e_test "$test_path"
    done
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
