#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
smoke_file="${ARK_README_TEST_FILE:-$(mktemp /tmp/ark-readme-test-smoke.XXXXXX.R)}"

mkdir -p "$(dirname -- "$smoke_file")"
: >"$smoke_file"
trap 'rm -f "$smoke_file"' EXIT

exec "$repo_root/scripts/start-readme-test-nvim.sh" \
  -- \
  --headless \
  -n \
  "$smoke_file" \
  -c "luafile $repo_root/testing/readme-minimal/smoke.lua"
