#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
setup_script="${repo_root}/scripts/ark-setup"
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/ark-source-setup-test.XXXXXX")
fake_bin="${tmpdir}/bin"
command_log="${tmpdir}/commands.log"

cleanup() {
  rm -rf -- "${tmpdir}"
}
trap cleanup EXIT INT TERM
mkdir -p -- "${fake_bin}"
: >"${command_log}"

cat >"${fake_bin}/nvim" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nvim %s\n' "$*" >>"${ARK_TEST_COMMAND_LOG}"
if [[ " ${*} " == *" --version "* ]]; then
  printf 'NVIM v0.11.3\n'
  exit 0
fi
if [[ "${*}" == *"required_runtime_revision"* ]]; then
  printf 'ARK_SETUP_VALUE=2\n'
  exit 0
fi
if [[ "${*}" == *"stdpath('data')"* ]]; then
  printf 'ARK_SETUP_VALUE=%s\n' "${ARK_TEST_NVIM_DATA}"
  exit 0
fi
exit 0
EOF

cat >"${fake_bin}/R" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'R %s\n' "$*" >>"${ARK_TEST_COMMAND_LOG}"
if [[ " ${*} " == *" --version "* ]]; then
  printf 'R version 4.2.0 (fixture)\n'
  exit 0
fi
if [[ " ${*} " == *" CMD SHLIB "* ]]; then
  : >ark_setup_probe.so
  exit 0
fi

previous=""
install_script=""
for argument in "$@"; do
  if [[ "${previous}" == "-f" ]]; then
    install_script=${argument}
    break
  fi
  previous=${argument}
done

if [[ "${install_script}" == */ark-install-bridge.R ]]; then
  while [[ $# -gt 0 && "$1" != "--args" ]]; do
    shift
  done
  shift
  package_path=${1:?missing package path}
  library_path=${2:?missing library path}
  stamp_path=${3:?missing stamp path}
  source_mtime=${4:?missing source mtime}
  runtime_revision=${5:?missing runtime revision}
  dependency_repo=${6-}
  printf 'bridge package=%s lib=%s source_mtime=%s revision=%s repo=%s\n' \
    "${package_path}" "${library_path}" "${source_mtime}" "${runtime_revision}" "${dependency_repo}" \
    >>"${ARK_TEST_COMMAND_LOG}"
  mkdir -p -- "${library_path}/arkbridge" "${library_path}/jsonlite"
  printf '%s\n' "{\"source_mtime\":1,\"runtime_revision\":${runtime_revision}}" >"${stamp_path}"
  exit 0
fi

exit 0
EOF

cat >"${fake_bin}/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cargo %s\n' "$*" >>"${ARK_TEST_COMMAND_LOG}"
if [[ " ${*} " == *" --version "* ]]; then
  printf 'cargo 1.97.0 (fixture)\n'
  exit 0
fi
if [[ " ${*} " == *" build "* ]]; then
  binary="${CARGO_TARGET_DIR:?missing CARGO_TARGET_DIR}/release/ark-lsp"
  mkdir -p -- "$(dirname -- "${binary}")"
  cat >"${binary}" <<'BINARY'
#!/usr/bin/env sh
if [ "${1:-}" = "--version" ] && [ "${2:-}" = "--json" ]; then
  printf '%s\n' "{\"component\":\"ark-lsp\",\"product_version\":\"${ARK_TEST_PRODUCT_VERSION}\",\"bridge_schema\":\"${ARK_TEST_BRIDGE_SCHEMA}\",\"crate_version\":\"fixture\",\"commit\":\"fixture\",\"target\":\"fixture\",\"profile\":\"release\",\"rustc\":\"fixture\"}"
  exit 0
fi
exit 2
BINARY
  chmod 755 "${binary}"
fi
EOF

chmod 755 "${fake_bin}/nvim" "${fake_bin}/R" "${fake_bin}/cargo"

export ARK_TEST_COMMAND_LOG="${command_log}"
export ARK_TEST_NVIM_DATA="${tmpdir}/nvim-data"
export ARK_TEST_PRODUCT_VERSION
ARK_TEST_PRODUCT_VERSION=$(sed -n 's/^[[:space:]]*"product_version":[[:space:]]*"\([^"]*\)".*/\1/p' "${repo_root}/release-manifest.json" | sed -n '1p')
export ARK_TEST_BRIDGE_SCHEMA
ARK_TEST_BRIDGE_SCHEMA=$(sed -n 's/^[[:space:]]*"bridge_schema":[[:space:]]*"\([^"]*\)".*/\1/p' "${repo_root}/release-manifest.json" | sed -n '1p')
export ARK_NVIM_CONSOLE_NVIM="${fake_bin}/nvim"
export ARK_NVIM_R_BIN="${fake_bin}/R"
export ARK_SETUP_CARGO_BIN="${fake_bin}/cargo"
export ARK_SETUP_DATA_DIR="${tmpdir}/nvim-data"
export ARK_SETUP_TARGET_DIR="${tmpdir}/target"
export ARK_SETUP_LOG_DIR="${tmpdir}/logs"
export PATH="${fake_bin}:/usr/bin:/bin"

session_lib="${tmpdir}/r-lib"
check_output="${tmpdir}/check.out"
"${setup_script}" --check --session-lib "${session_lib}" >"${check_output}"
grep -q "ready for a source build" "${check_output}"
if [[ -e "${tmpdir}/target/release/ark-lsp" || -e "${session_lib}/arkbridge" ]]; then
  echo "check-only setup unexpectedly built or installed a component" >&2
  exit 1
fi
grep -q '^cargo --version$' "${command_log}"
grep -q 'CMD SHLIB ark_setup_probe.c' "${command_log}"
if grep -q '^cargo build ' "${command_log}"; then
  echo "check-only setup unexpectedly invoked cargo build" >&2
  exit 1
fi

: >"${command_log}"
setup_output="${tmpdir}/setup.out"
"${setup_script}" --session-lib "${session_lib}" >"${setup_output}"
grep -q "Ark source setup is complete" "${setup_output}"
grep -q '^cargo build --locked --release -p ark-lsp$' "${command_log}"
grep -q 'revision=2 repo=https://cloud.r-project.org' "${command_log}"
grep -q 'ark-lsp discovery mismatch' "${command_log}"
test -x "${tmpdir}/target/release/ark-lsp"
test -d "${session_lib}/arkbridge"
test -f "${session_lib}/.arkbridge-install.json"

: >"${command_log}"
rm -rf -- "${session_lib}"
"${setup_script}" --session-lib "${session_lib}" --no-install-r-deps >/dev/null
grep -q 'revision=2 repo=$' "${command_log}"

missing_output="${tmpdir}/missing.out"
if ARK_SETUP_CARGO_BIN="${tmpdir}/missing-cargo" \
  "${setup_script}" --check --session-lib "${tmpdir}/missing-r-lib" >"${missing_output}" 2>&1
then
  echo "setup unexpectedly accepted a missing Cargo executable" >&2
  exit 1
fi
grep -q "Cargo is not available" "${missing_output}"
grep -q "https://rustup.rs/" "${missing_output}"

printf 'source setup tests passed\n'
