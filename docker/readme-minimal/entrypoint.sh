#!/usr/bin/env bash
set -euo pipefail

repo_root=/work/ark.nvim

cd "${repo_root}"

case "${1:-interactive}" in
  interactive)
    shift
    exec ./scripts/start-readme-test-nvim.sh "$@"
    ;;
  smoke)
    shift
    exec /usr/local/bin/ark-readme-test-smoke "$@"
    ;;
  shell | bash)
    shift
    exec /bin/bash "$@"
    ;;
  -*)
    exec ./scripts/start-readme-test-nvim.sh "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
