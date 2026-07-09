#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
check_root=$(mktemp -d /tmp/arkbridge-check.XXXXXX)

cleanup() {
  rm -rf -- "${check_root}"
}
trap cleanup EXIT INT TERM

(
  cd "${check_root}"
  R CMD build --no-build-vignettes --no-manual "${repo_root}/packages/arkbridge"
)

package_tarball=$(find "${check_root}" -maxdepth 1 -type f -name 'arkbridge_*.tar.gz' -print -quit)
if [[ -z "${package_tarball}" ]]; then
  echo "R CMD build did not produce an arkbridge tarball" >&2
  exit 1
fi

(
  cd "${check_root}"
  R CMD check --no-manual "${package_tarball}"
)

check_dir=$(find "${check_root}" -maxdepth 1 -type d -name 'arkbridge.Rcheck' -print -quit)
log="${check_dir}/00check.log"
if [[ ! -f "${log}" ]] || ! tail -n 5 "${log}" | grep -q '^Status: OK$'; then
  echo "arkbridge package check did not finish with zero warnings and notes" >&2
  [[ -f "${log}" ]] && tail -n 40 "${log}" >&2
  exit 1
fi

echo "arkbridge package check passed with zero warnings and notes"
