#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  install-release.sh install --version <version> --target <triple> \
    --asset-url <url> --checksum-url <url> --install-root <dir>
  install-release.sh rollback --install-root <dir>

Installs immutable, checksummed ark-lsp release assets into an Ark-owned data
directory. The current pointer changes only after the new binary passes its
version smoke check. The previous pointer provides one-step rollback.
EOF
}

mode=${1:-}
if [[ -z "${mode}" ]]; then
  usage >&2
  exit 2
fi
shift

version=""
target=""
asset_url=""
checksum_url=""
install_root=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version=${2:?missing value for --version}
      shift 2
      ;;
    --target)
      target=${2:?missing value for --target}
      shift 2
      ;;
    --asset-url)
      asset_url=${2:?missing value for --asset-url}
      shift 2
      ;;
    --checksum-url)
      checksum_url=${2:?missing value for --checksum-url}
      shift 2
      ;;
    --install-root)
      install_root=${2:?missing value for --install-root}
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${install_root}" ]]; then
  echo "--install-root is required" >&2
  exit 2
fi

releases_dir="${install_root}/releases"
lock_dir="${install_root}/.install-lock"
staging_dir=""

cleanup() {
  local exit_code=$?
  if [[ -n "${staging_dir}" && -d "${staging_dir}" ]]; then
    rm -rf -- "${staging_dir}"
  fi
  rmdir "${lock_dir}" 2>/dev/null || true
  exit "${exit_code}"
}

mkdir -p "${releases_dir}"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "another Ark release install is already in progress: ${lock_dir}" >&2
  exit 1
fi
trap cleanup EXIT INT TERM

atomic_link() {
  local target_path=$1
  local link_path=$2
  local next_link="${link_path}.next.$$"

  rm -f -- "${next_link}"
  ln -s -- "${target_path}" "${next_link}"
  mv -Tf -- "${next_link}" "${link_path}"
}

binary_metadata() {
  local binary=$1
  "${binary}" --version --json
}

validate_binary() {
  local binary=$1
  local expected_version=$2
  local expected_target=$3
  local metadata

  metadata=$(binary_metadata "${binary}")
  python3 - "${expected_version}" "${expected_target}" "${metadata}" <<'PY'
import json
import sys

expected_version, expected_target, raw = sys.argv[1:]
metadata = json.loads(raw)
if metadata.get("component") != "ark-lsp":
    raise SystemExit("release asset does not identify itself as ark-lsp")
if metadata.get("product_version") != expected_version:
    raise SystemExit(
        "release asset product version mismatch: "
        f"expected {expected_version}, got {metadata.get('product_version')}"
    )
if expected_target and metadata.get("target") != expected_target:
    raise SystemExit(
        "release asset target mismatch: "
        f"expected {expected_target}, got {metadata.get('target')}"
    )
if metadata.get("profile") != "release":
    raise SystemExit("release asset is not an optimized release build")
PY
}

install_release() {
  if [[ -z "${version}" || -z "${target}" || -z "${asset_url}" || -z "${checksum_url}" ]]; then
    echo "install requires --version, --target, --asset-url, and --checksum-url" >&2
    exit 2
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to install Ark release assets" >&2
    exit 1
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum is required to verify Ark release assets" >&2
    exit 1
  fi

  local release_dir="${releases_dir}/${version}"
  local release_binary="${release_dir}/ark-lsp"

  if [[ ! -x "${release_binary}" ]]; then
    staging_dir=$(mktemp -d "${releases_dir}/.staging-${version}.XXXXXX")
    local staged_binary="${staging_dir}/ark-lsp"
    local staged_checksum="${staging_dir}/ark-lsp.sha256"

    curl --fail --location --silent --show-error "${asset_url}" --output "${staged_binary}"
    curl --fail --location --silent --show-error "${checksum_url}" --output "${staged_checksum}"

    local expected actual
    expected=$(awk 'NR == 1 { print tolower($1) }' "${staged_checksum}")
    if [[ ! "${expected}" =~ ^[0-9a-f]{64}$ ]]; then
      echo "release checksum file is malformed" >&2
      exit 1
    fi
    actual=$(sha256sum "${staged_binary}" | awk '{ print tolower($1) }')
    if [[ "${actual}" != "${expected}" ]]; then
      echo "release checksum mismatch" >&2
      exit 1
    fi

    chmod 755 "${staged_binary}"
    validate_binary "${staged_binary}" "${version}" "${target}"

    if [[ -e "${release_dir}" ]]; then
      echo "release directory exists but is not a valid immutable install: ${release_dir}" >&2
      exit 1
    fi
    mv -- "${staging_dir}" "${release_dir}"
    staging_dir=""
  fi

  validate_binary "${release_binary}" "${version}" "${target}"

  local old_current
  old_current=$(readlink -f -- "${install_root}/current" 2>/dev/null || true)
  if [[ -n "${old_current}" && "${old_current}" != "${release_dir}" ]]; then
    atomic_link "${old_current}" "${install_root}/previous"
  fi
  atomic_link "${release_dir}" "${install_root}/current"
  printf 'installed ark-lsp %s at %s\n' "${version}" "${release_binary}"
}

rollback_release() {
  local previous current
  previous=$(readlink -f -- "${install_root}/previous" 2>/dev/null || true)
  current=$(readlink -f -- "${install_root}/current" 2>/dev/null || true)
  if [[ -z "${previous}" || ! -x "${previous}/ark-lsp" ]]; then
    echo "no previous Ark release is available for rollback" >&2
    exit 1
  fi

  binary_metadata "${previous}/ark-lsp" >/dev/null
  atomic_link "${previous}" "${install_root}/current"
  if [[ -n "${current}" && "${current}" != "${previous}" ]]; then
    atomic_link "${current}" "${install_root}/previous"
  fi
  printf 'rolled back ark-lsp to %s\n' "${previous}"
}

case "${mode}" in
  install)
    install_release
    ;;
  rollback)
    rollback_release
    ;;
  *)
    echo "unknown mode: ${mode}" >&2
    usage >&2
    exit 2
    ;;
esac
