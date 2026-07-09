#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
dist_dir="${1:-${repo_root}/dist}"

readarray -t release_fields < <(
  python3 - "${repo_root}/release-manifest.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
target = manifest["release_targets"][0]
print(manifest["product_version"])
print(manifest["release_tag"])
print(target["rust_target"])
print(target["asset"])
print(target["checksum_asset"])
PY
)

product_version=${release_fields[0]}
release_tag=${release_fields[1]}
rust_target=${release_fields[2]}
asset=${release_fields[3]}
checksum_asset=${release_fields[4]}
build_commit=$(git -C "${repo_root}" rev-parse HEAD)

if [[ "${ARK_SKIP_RELEASE_BUILD:-0}" != "1" ]]; then
  ARK_BUILD_COMMIT="${build_commit}" cargo build --locked --release -p ark-lsp
fi

source_binary="${repo_root}/target/release/ark-lsp"
if [[ ! -x "${source_binary}" ]]; then
  echo "release binary is missing: ${source_binary}" >&2
  exit 1
fi

mkdir -p "${dist_dir}"
install -m 755 "${source_binary}" "${dist_dir}/${asset}"
if command -v strip >/dev/null 2>&1; then
  strip "${dist_dir}/${asset}"
fi

python3 "${repo_root}/scripts/verify-release-manifest.py" \
  --artifact "${dist_dir}/${asset}"

(
  cd "${dist_dir}"
  sha256sum "${asset}" >"${checksum_asset}"
)

asset_sha256=$(awk 'NR == 1 { print $1 }' "${dist_dir}/${checksum_asset}")
asset_size=$(stat -c '%s' "${dist_dir}/${asset}")
rustc_version=$(rustc -V)
cargo_version=$(cargo -V)
glibc_version=$(ldd --version | sed -n '1p')

python3 - "${dist_dir}/build-metadata.json" <<PY
import json
import pathlib

metadata = {
    "product_version": ${product_version@Q},
    "release_tag": ${release_tag@Q},
    "target": ${rust_target@Q},
    "asset": ${asset@Q},
    "sha256": ${asset_sha256@Q},
    "size_bytes": int(${asset_size@Q}),
    "commit": ${build_commit@Q},
    "rustc": ${rustc_version@Q},
    "cargo": ${cargo_version@Q},
    "build_libc": ${glibc_version@Q},
}
pathlib.Path(${dist_dir@Q}, "build-metadata.json").write_text(
    json.dumps(metadata, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

printf 'release artifact: %s\n' "${dist_dir}/${asset}"
printf 'release checksum: %s\n' "${dist_dir}/${checksum_asset}"
