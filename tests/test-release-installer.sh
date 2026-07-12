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
  local bridge_schema=${3:-v1}
  local asset="${assets}/ark-lsp-${version}-${profile}-${bridge_schema}"

  cat >"${asset}" <<EOF
#!/usr/bin/env sh
if [ "\${1:-}" = "--version" ] && [ "\${2:-}" = "--json" ]; then
  printf '%s\n' '{"component":"ark-lsp","product_version":"${version}","bridge_schema":"${bridge_schema}","crate_version":"fixture","commit":"fixture","target":"${target}","profile":"${profile}","rustc":"fixture"}'
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
    --bridge-schema "v1" \
    --asset-url "file://${asset}" \
    --checksum-url "file://${checksum}" \
    --install-root "${install_root}"
}

current_version() {
  "${install_root}/current/ark-lsp" --version --json \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["product_version"])'
}

asset_v1=$(make_asset "0.1.0-alpha.1")

# If atomic owner metadata publication fails after mkdir succeeds, the process
# must release the lock it owns rather than wedging every future install.
lock_failure_root="${tmpdir}/lock-owner-failure"
fake_bin="${tmpdir}/fake-bin"
real_mv=$(command -v mv)
mkdir -p "${fake_bin}"
cat >"${fake_bin}/mv" <<EOF
#!/usr/bin/env sh
last=""
for argument in "\$@"; do
  last="\${argument}"
done
case "\${last}" in
  */.install-lock/owner) exit 70 ;;
esac
exec "${real_mv}" "\$@"
EOF
chmod 755 "${fake_bin}/mv"
if PATH="${fake_bin}:${PATH}" "${installer}" install \
  --version "0.1.0-alpha.1" \
  --target "${target}" \
  --bridge-schema "v1" \
  --asset-url "file://${asset_v1}" \
  --checksum-url "file://${asset_v1}.sha256" \
  --install-root "${lock_failure_root}" >/dev/null 2>&1
then
  echo "owner metadata publication failure unexpectedly installed" >&2
  exit 1
fi
if [[ -e "${lock_failure_root}/.install-lock" ]]; then
  echo "owner metadata publication failure left a stale lock" >&2
  exit 1
fi

install_asset "0.1.0-alpha.1" "${asset_v1}" >/dev/null
[[ "$(current_version)" == "0.1.0-alpha.1" ]]

# A killed installer can leave the mkdir-based lock behind. The next install
# must reclaim an ownerless/dead lock instead of permanently wedging updates.
mkdir "${install_root}/.install-lock"
printf 'pid=%s\nstart_id=%s\n' 99999999 1 >"${install_root}/.install-lock/owner"
install_asset "0.1.0-alpha.1" "${asset_v1}" >/dev/null
[[ "$(current_version)" == "0.1.0-alpha.1" ]]

# Conversely, a lock owned by a live installer must never be stolen.
mkdir "${install_root}/.install-lock"
start_id=""
if [[ -r "/proc/$$/stat" ]]; then
  start_id=$(awk '{ print $22 }' "/proc/$$/stat")
fi
printf 'pid=%s\nstart_id=%s\n' "$$" "${start_id}" >"${install_root}/.install-lock/owner"
if install_asset "0.1.0-alpha.1" "${asset_v1}" >/dev/null 2>&1; then
  echo "live installer lock was unexpectedly stolen" >&2
  exit 1
fi
rm -rf -- "${install_root}/.install-lock"

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

wrong_schema_asset=$(make_asset "0.1.0-alpha.2" "release" "v999")
if install_asset "0.1.0-alpha.2" "${wrong_schema_asset}" >/dev/null 2>&1; then
  echo "incompatible bridge schema unexpectedly installed" >&2
  exit 1
fi
[[ "$(current_version)" == "0.1.0-alpha.1" ]]

asset_v2=$(make_asset "0.1.0-alpha.2")
install_asset "0.1.0-alpha.2" "${asset_v2}" >/dev/null
[[ "$(current_version)" == "0.1.0-alpha.2" ]]
[[ "$(readlink -f "${install_root}/previous")" == "${install_root}/releases/0.1.0-alpha.1" ]]

# A previous binary with the right product version but the wrong bridge schema
# must not be activated. This isolates schema validation from version checks.
wrong_previous_schema=$(make_asset "0.1.0-alpha.1" "release" "v999")
cp "${wrong_previous_schema}" "${install_root}/releases/0.1.0-alpha.1/ark-lsp"
if "${installer}" rollback \
  --version "0.1.0-alpha.1" \
  --target "${target}" \
  --bridge-schema "v1" \
  --install-root "${install_root}" >/dev/null 2>&1
then
  echo "incompatible previous bridge schema unexpectedly activated" >&2
  exit 1
fi
[[ "$(current_version)" == "0.1.0-alpha.2" ]]
cp "${asset_v1}" "${install_root}/releases/0.1.0-alpha.1/ark-lsp"

# Rollback is a whole-product operation under exact-version compatibility. A
# new plugin must not activate its previous, incompatible LSP. After the plugin
# checkout is pinned back to the prior release, its expected version authorizes
# activation of that matching binary.
if "${installer}" rollback \
  --version "0.1.0-alpha.2" \
  --target "${target}" \
  --bridge-schema "v1" \
  --install-root "${install_root}" >/dev/null 2>&1
then
  echo "incompatible previous release unexpectedly activated" >&2
  exit 1
fi
[[ "$(current_version)" == "0.1.0-alpha.2" ]]

"${installer}" rollback \
  --version "0.1.0-alpha.1" \
  --target "${target}" \
  --bridge-schema "v1" \
  --install-root "${install_root}" >/dev/null
[[ "$(current_version)" == "0.1.0-alpha.1" ]]
[[ "$(readlink -f "${install_root}/previous")" == "${install_root}/releases/0.1.0-alpha.2" ]]

printf 'release installer tests passed\n'
