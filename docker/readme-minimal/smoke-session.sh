#!/usr/bin/env bash
set -euo pipefail

repo_root=/work/ark.nvim
log_file="${ARK_DOCKER_README_SMOKE_LOG:-/tmp/ark-readme-smoke.log}"
exit_file="${ARK_DOCKER_README_SMOKE_EXIT:-/tmp/ark-readme-smoke.exit}"

cd "${repo_root}"

if ./scripts/smoke-readme-test-config.sh >"${log_file}" 2>&1; then
  printf '0\n' >"${exit_file}"
  exit 0
fi

status=$?
printf '%s\n' "${status}" >"${exit_file}"
exit "${status}"
