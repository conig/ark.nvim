#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "${repo_root}"

cargo check -p ark-lsp

features=$(cargo tree -p ark-lsp -e features -i ark-lsp-core)
if grep -Fq 'ark-lsp-core feature "attached-runtime"' <<<"${features}"; then
  echo "ark-lsp unexpectedly enables ark-lsp-core's attached-runtime feature" >&2
  exit 1
fi

if rg -n 'crate::(console|runtime)|\br_task\(' crates/ark-lsp/src; then
  echo "ark-lsp source directly references attached-runtime infrastructure" >&2
  exit 1
fi

cargo build -p ark-lsp
error_log=$(mktemp /tmp/ark-detached-boundary.XXXXXX.log)
trap 'rm -f -- "${error_log}"' EXIT INT TERM
if target/debug/ark-lsp --runtime-mode attached >"${error_log}" 2>&1; then
  echo "detached ark-lsp accepted the unsupported attached runtime mode" >&2
  exit 1
fi
grep -Fq 'Expected `detached`' "${error_log}"

echo "detached ark-lsp boundary contracts passed"
