#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  install-release.sh install --version <version> --target <triple> \
    --bridge-schema <schema> \
    --asset-url <url> --checksum-url <url> --install-root <dir>
  install-release.sh rollback --version <plugin-version> --target <triple> \
    --bridge-schema <schema> \
    --install-root <dir>

Installs immutable, checksummed ark-lsp release assets into an Ark-owned data
directory. The current pointer changes only after the new binary passes its
version smoke check. The previous pointer provides one-step rollback after the
plugin checkout has been pinned to that same previous release.
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
bridge_schema=""
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
    --bridge-schema)
      bridge_schema=${2:?missing value for --bridge-schema}
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
lock_owner="${lock_dir}/owner"
lock_owner_staging="${lock_dir}/owner.$$"
lock_token=""
lock_identity=""
lock_acquired=0
staging_dir=""

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  if [[ -n "${staging_dir}" && -d "${staging_dir}" ]]; then
    rm -rf -- "${staging_dir}"
  fi
  if [[ "${lock_acquired}" -eq 1 && -d "${lock_dir}" ]]; then
    local current_identity owner_token
    current_identity=$(stat -c '%d:%i' "${lock_dir}" 2>/dev/null || true)
    owner_token=$(lock_field token)
    if [[ "${current_identity}" == "${lock_identity}" ]] \
      && { [[ -z "${owner_token}" ]] || [[ "${owner_token}" == "${lock_token}" ]]; }
    then
      rm -f -- "${lock_owner_staging}" "${lock_owner}"
      rmdir "${lock_dir}" 2>/dev/null || true
    fi
  fi
  exit "${exit_code}"
}

process_start_id() {
  local pid=$1
  if [[ -r "/proc/${pid}/stat" ]]; then
    awk '{ print $22 }' "/proc/${pid}/stat" 2>/dev/null || true
  fi
}

lock_field() {
  local field=$1
  if [[ -f "${lock_owner}" ]]; then
    sed -n "s/^${field}=//p" "${lock_owner}" | sed -n '1p'
  fi
}

lock_must_be_preserved() {
  local pid stored_start current_start modified now
  pid=$(lock_field pid)
  stored_start=$(lock_field start_id)

  if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    current_start=$(process_start_id "${pid}")
    if [[ -z "${stored_start}" || -z "${current_start}" || "${stored_start}" == "${current_start}" ]]; then
      return 0
    fi
    return 1
  fi

  # Do not steal a just-created lock before its owner has written metadata.
  # Ownerless or malformed locks become reclaimable after a short grace period.
  if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
    modified=$(stat -c '%Y' "${lock_dir}" 2>/dev/null || printf '0')
    now=$(date +%s)
    if [[ "${modified}" =~ ^[0-9]+$ ]] && (( now - modified < 30 )); then
      return 0
    fi
  fi

  return 1
}

write_lock_owner() {
  local start_id=$1
  printf 'pid=%s\nstart_id=%s\ntoken=%s\n' "$$" "${start_id}" "${lock_token}" >"${lock_owner_staging}"
  mv -- "${lock_owner_staging}" "${lock_owner}"
}

acquire_install_lock() {
  local attempt stale_lock start_id
  for attempt in 1 2 3; do
    if mkdir "${lock_dir}" 2>/dev/null; then
      lock_acquired=1
      lock_identity=$(stat -c '%d:%i' "${lock_dir}" 2>/dev/null || true)
      start_id=$(process_start_id "$$")
      lock_token="$$:${start_id:-unknown}"
      write_lock_owner "${start_id}"
      return 0
    fi
    if lock_must_be_preserved; then
      echo "another Ark release install is already in progress: ${lock_dir}" >&2
      return 1
    fi

    stale_lock="${lock_dir}.stale.$$-${attempt}"
    if mv -- "${lock_dir}" "${stale_lock}" 2>/dev/null; then
      rm -rf -- "${stale_lock}"
      echo "recovered stale Ark release install lock: ${lock_dir}" >&2
    fi
  done

  echo "could not acquire Ark release install lock: ${lock_dir}" >&2
  return 1
}

mkdir -p "${releases_dir}"
trap cleanup EXIT INT TERM
acquire_install_lock

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
  local expected_bridge_schema=$4
  local metadata

  metadata=$(binary_metadata "${binary}")
  python3 - "${expected_version}" "${expected_target}" "${expected_bridge_schema}" "${metadata}" <<'PY'
import json
import sys

expected_version, expected_target, expected_bridge_schema, raw = sys.argv[1:]
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
if metadata.get("bridge_schema") != expected_bridge_schema:
    raise SystemExit(
        "release asset bridge schema mismatch: "
        f"expected {expected_bridge_schema}, got {metadata.get('bridge_schema')}"
    )
if metadata.get("profile") != "release":
    raise SystemExit("release asset is not an optimized release build")
PY
}

install_release() {
  if [[ -z "${version}" || -z "${target}" || -z "${bridge_schema}" || -z "${asset_url}" || -z "${checksum_url}" ]]; then
    echo "install requires --version, --target, --bridge-schema, --asset-url, and --checksum-url" >&2
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
    validate_binary "${staged_binary}" "${version}" "${target}" "${bridge_schema}"

    if [[ -e "${release_dir}" ]]; then
      echo "release directory exists but is not a valid immutable install: ${release_dir}" >&2
      exit 1
    fi
    mv -- "${staging_dir}" "${release_dir}"
    staging_dir=""
  fi

  validate_binary "${release_binary}" "${version}" "${target}" "${bridge_schema}"

  local old_current
  old_current=$(readlink -f -- "${install_root}/current" 2>/dev/null || true)
  if [[ -n "${old_current}" && "${old_current}" != "${release_dir}" ]]; then
    atomic_link "${old_current}" "${install_root}/previous"
  fi
  atomic_link "${release_dir}" "${install_root}/current"
  printf 'installed ark-lsp %s at %s\n' "${version}" "${release_binary}"
}

rollback_release() {
  if [[ -z "${version}" || -z "${target}" || -z "${bridge_schema}" ]]; then
    echo "rollback requires --version, --target, and --bridge-schema from the active plugin release" >&2
    exit 2
  fi

  local previous current metadata previous_version validation_error
  previous=$(readlink -f -- "${install_root}/previous" 2>/dev/null || true)
  current=$(readlink -f -- "${install_root}/current" 2>/dev/null || true)
  if [[ -z "${previous}" || ! -x "${previous}/ark-lsp" ]]; then
    echo "no previous Ark release is available for rollback" >&2
    exit 1
  fi

  if ! metadata=$(binary_metadata "${previous}/ark-lsp"); then
    echo "previous Ark release metadata is unreadable; reinstall the desired plugin release" >&2
    exit 1
  fi
  previous_version=$(python3 - "${metadata}" <<'PY'
import json
import sys

print(json.loads(sys.argv[1]).get("product_version", "unknown"))
PY
  )
  if ! validation_error=$(validate_binary "${previous}/ark-lsp" "${version}" "${target}" "${bridge_schema}" 2>&1); then
    echo "previous ark-lsp ${previous_version} is incompatible with active plugin ${version}" >&2
    echo "pin the plugin checkout to v${previous_version} on the matching platform, then rerun :Ark rollback" >&2
    echo "${validation_error}" >&2
    exit 1
  fi

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
