#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
skip_e2e=0
skip_r=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-e2e)
      skip_e2e=1
      shift
      ;;
    --skip-r)
      skip_r=1
      shift
      ;;
    -h | --help)
      cat <<'EOF'
Usage: scripts/verify-product.sh [--skip-e2e] [--skip-r]

Runs the required, reproducible product gate. Broader retained-upstream and
serial pre-release coverage lives behind `just verify-upstream-compat` and
`scripts/run-full-suite.sh`.
EOF
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

failures=()

run_step() {
  local label=$1
  shift
  printf '\n==> %s\n' "${label}"
  if "$@"; then
    printf 'PASS: %s\n' "${label}"
  else
    local status=$?
    printf 'FAIL: %s (exit %s)\n' "${label}" "${status}" >&2
    failures+=("${label}")
  fi
}

cd "${repo_root}"
run_step "release manifest" python3 scripts/verify-release-manifest.py
run_step "Rust formatting" cargo +nightly-2025-07-18 fmt --all -- --check
run_step "product clippy" cargo clippy -p ark-lsp --all-targets -- -D warnings
run_step "ark-lsp-core unit tests" cargo test -p ark-lsp-core --lib
run_step "ark-lsp metadata tests" cargo test -p ark-lsp
run_step "release installer" tests/test-release-installer.sh

if [[ "${skip_r}" -eq 0 ]]; then
  run_step "arkbridge R CMD check" scripts/check-arkbridge.sh
fi

if [[ "${skip_e2e}" -eq 0 ]]; then
  run_step "release manifest and discovery E2E" \
    scripts/run-e2e-test.sh --init NONE tests/e2e/release_manifest_and_discovery.lua
  run_step "detached static parity E2E" \
    scripts/run-e2e-test.sh --init NONE tests/e2e/detached_parity.lua
fi

printf '\n==> Product verification summary\n'
if [[ "${#failures[@]}" -eq 0 ]]; then
  echo "PASS: required product gate completed without failures"
  exit 0
fi

printf 'FAIL: %s product verification step(s) failed\n' "${#failures[@]}" >&2
printf ' - %s\n' "${failures[@]}" >&2
exit 1
