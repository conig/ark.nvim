#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
resolver="${repo_root}/scripts/test-manifest.py"

python3 "${resolver}" validate

total=$(find "${repo_root}/tests/e2e" -maxdepth 1 -type f -name '*.lua' | wc -l)
classified=$(python3 "${resolver}" list --tier full | wc -l)
required=$(python3 "${resolver}" list --tier required | wc -l)
excluded=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["exclude"]))' \
  "${repo_root}/tests/test-manifest.json")
test "$total" -eq "$((classified + excluded))"
test "$required" -gt 2

python3 "${resolver}" describe --tier required --format json |
  python3 -c 'import json,sys; records=json.load(sys.stdin); assert {r["tier"] for r in records} == {"unit", "fast"}'

python3 "${resolver}" describe --tier serial-integration --format json |
  python3 -c 'import json,sys; records=json.load(sys.stdin); assert records; assert all({"neovim", "r", "tmux"} <= set(r["dependencies"]) for r in records)'

if python3 "${resolver}" list --tier impossible >/dev/null 2>&1; then
  echo "manifest resolver accepted an unknown tier" >&2
  exit 1
fi

malformed=$(mktemp /tmp/ark-test-manifest.XXXXXX.json)
trap 'rm -f -- "${malformed}"' EXIT INT TERM
printf '%s\n' '{"defaults":{"tier":"unknown","serial":true,"dependencies":[]}}' >"${malformed}"
if python3 "${resolver}" validate --manifest "${malformed}" >/dev/null 2>&1; then
  echo "manifest resolver accepted malformed tier metadata" >&2
  exit 1
fi

echo "test manifest validation contracts passed"
