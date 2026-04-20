#!/usr/bin/env bash
set -euo pipefail

session_name="${ARK_DOCKER_README_SMOKE_SESSION:-ark-readme-smoke}"
log_file="${ARK_DOCKER_README_SMOKE_LOG:-/tmp/ark-readme-smoke.log}"
exit_file="${ARK_DOCKER_README_SMOKE_EXIT:-/tmp/ark-readme-smoke.exit}"
timeout_sec="${ARK_DOCKER_README_SMOKE_TIMEOUT_SEC:-180}"

rm -f "${log_file}" "${exit_file}"
tmux kill-session -t "${session_name}" >/dev/null 2>&1 || true

tmux new-session -d -s "${session_name}" \
  "ARK_DOCKER_README_SMOKE_LOG=${log_file} ARK_DOCKER_README_SMOKE_EXIT=${exit_file} /usr/local/bin/ark-readme-test-smoke-session"

elapsed=0
while tmux has-session -t "${session_name}" >/dev/null 2>&1; do
  if (( elapsed >= timeout_sec )); then
    echo "timed out waiting for Docker README smoke session after ${timeout_sec}s" >&2
    tmux kill-session -t "${session_name}" >/dev/null 2>&1 || true
    if [[ -f "${log_file}" ]]; then
      cat "${log_file}"
    fi
    exit 124
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

status=1
if [[ -f "${exit_file}" ]]; then
  status="$(tr -d '\n' <"${exit_file}")"
fi

if [[ -f "${log_file}" ]]; then
  cat "${log_file}"
fi

exit "${status}"
