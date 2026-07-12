#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d /tmp/ark-python-portability.XXXXXX)

cleanup() {
  rm -rf -- "${tmpdir}"
}
trap cleanup EXIT INT TERM

# Ubuntu 22.04 ships Python 3.10, which does not include the Python 3.11+
# `tomllib` module. Shadow it with an import failure so this test exercises the
# supported release-builder shape even when run under a newer local Python.
printf '%s\n' 'raise ModuleNotFoundError("tomllib is unavailable", name="tomllib")' \
  >"${tmpdir}/tomllib.py"

for script in \
  scripts/verify-release-manifest.py \
  scripts/check-only-workspace-dependencies.py
do
  PYTHONPATH="${tmpdir}" python3 "${repo_root}/${script}"
done

PYTHONPATH="${tmpdir}" python3 "${repo_root}/tests/test-workspace-dependency-parser.py"

printf 'ambient Python portability tests passed\n'
