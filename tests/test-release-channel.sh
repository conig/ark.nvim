#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper="${repo_root}/scripts/release-publication-flags.sh"

assert_flags() {
  local channel=$1
  local expected=$2
  local actual
  actual=$("${helper}" "${channel}")
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'unexpected publication flags for %s:\n%s\n' "${channel}" "${actual}" >&2
    exit 1
  fi
}

assert_flags alpha $'--prerelease\n--latest=false'
assert_flags beta $'--prerelease\n--latest=false'
assert_flags stable '--latest'

if "${helper}" nightly >/dev/null 2>&1; then
  echo "unsupported release channel unexpectedly produced publication flags" >&2
  exit 1
fi

printf 'release channel publication tests passed\n'
