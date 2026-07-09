#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="${repo_root}/scripts/install-release.sh"
tmpdir=$(mktemp -d /tmp/ark-release-installer.XXXXXX)
assets="${tmpdir}/assets"
install_root="${tmpdir}/install"
target="x86_64-unknown-linux-gnu"

cleanup() {
  rm -rf -- "${tmpdir}"
}
trap cleanup EXIT INT TERM
mkdir -p "${assets}"

make_asset() {
  local version=$1
  local profile=${2:-release}
  local asset="${assets}/ark-lsp-${version}"

  cat >"${asset}" <<EOF
#!/usr/bin/env sh
if [ "\${1:-}" = "--version" ] && [ "\${2:-}" = "--json" ]; then
  printf '%s\n' '{"component":"ark-lsp","product_version":"${version}","bridge_schema":"v1","crate_version":"fixture","commit":"fixture","target":"${target}","profile":"${profile}","rustc":"fixture"}'
  exit 0
fi
exit 2
EOF
  chmod 755 "${asset}"
  sha256sum "${asset}" >"${asset}.sha256"
  printf '%s\n' "${asset}"
}

install_asset() {
  local version=$1
  local asset=$2
  local checksum=${3:-${asset}.sha256}

  "${installer}" install \
    --version "${version}" \
    --target "${target}" \
    --asset-url "file://${asset}" \
    --checksum-url "file://${checksum}" \
    --install-root "${install_root}"
}

current_version() {
  "${install_root}/current/ark-lsp" --version --json \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["product_version"])'
}

asset_v1=$(make_asset "0.1.0-alpha.1")
install_asset "0.1.0-alpha.1" "${asset_v1}" >/dev/null
[[ "$(current_version)" == "0.1.0-alpha.1" ]]

bad_checksum="${assets}/bad.sha256"
printf '%064d  ark-lsp\n' 0 >"${bad_checksum}"
asset_bad=$(make_asset "0.1.0-alpha.2")
if install_asset "0.1.0-alpha.2" "${asset_bad}" "${bad_checksum}" >/dev/null 2>&1; then
  echo "checksum mismatch unexpectedly installed" >&2
  exit 1
fi
[[ "$(current_version)" == "0.1.0-alpha.1" ]]

if install_asset "0.1.0-alpha.2" "${assets}/missing" "${assets}/missing.sha256" >/dev/null 2>&1; then
  echo "interrupted or missing download unexpectedly replaced current" >&2
  exit 1
fi
[[ "$(current_version)" == "0.1.0-alpha.1" ]]

debug_asset=$(make_asset "0.1.0-alpha.2" "debug")
if install_asset "0.1.0-alpha.2" "${debug_asset}" >/dev/null 2>&1; then
  echo "unoptimized artifact unexpectedly installed" >&2
  exit 1
fi
[[ "$(current_version)" == "0.1.0-alpha.1" ]]

wrong_version_asset=$(make_asset "9.9.9")
if install_asset "0.1.0-alpha.2" "${wrong_version_asset}" >/dev/null 2>&1; then
  echo "incompatible product version unexpectedly installed" >&2
  exit 1
fi
[[ "$(current_version)" == "0.1.0-alpha.1" ]]

asset_v2=$(make_asset "0.1.0-alpha.2")
install_asset "0.1.0-alpha.2" "${asset_v2}" >/dev/null
[[ "$(current_version)" == "0.1.0-alpha.2" ]]
[[ "$(readlink -f "${install_root}/previous")" == "${install_root}/releases/0.1.0-alpha.1" ]]

"${installer}" rollback --install-root "${install_root}" >/dev/null
[[ "$(current_version)" == "0.1.0-alpha.1" ]]
[[ "$(readlink -f "${install_root}/previous")" == "${install_root}/releases/0.1.0-alpha.2" ]]

printf 'release installer tests passed\n'
