#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d /tmp/ark-e2e-fixture.XXXXXX)
trap 'rm -rf -- "${tmpdir}"' EXIT INT TERM

source_root="${tmpdir}/installed/example.nvim"
mkdir -p "$source_root"
git -C "$source_root" init -q
printf 'fixture\n' >"${source_root}/README"
git -C "$source_root" add README
git -C "$source_root" -c user.name=Ark -c user.email=ark@example.invalid commit -qm fixture
revision=$(git -C "$source_root" rev-parse HEAD)

lock="${tmpdir}/lock.json"
printf '{"schema_version":1,"plugins":[{"name":"example.nvim","repository":"unused","revision":"%s"}]}\n' \
  "$revision" >"$lock"

data_home="${tmpdir}/data"
mkdir -p "${data_home}/nvim/lazy"
ln -s "${tmpdir}/missing" "${data_home}/nvim/lazy/example.nvim"
python3 "${repo_root}/scripts/prepare-e2e-fixture.py" \
  --lock "$lock" --data-home "$data_home" --installed-root "${tmpdir}/installed"
test "$(git -C "${data_home}/nvim/lazy/example.nvim" rev-parse HEAD)" = "$revision"

git -C "$source_root" -c user.name=Ark -c user.email=ark@example.invalid commit --allow-empty -qm newer
rm -f "${data_home}/nvim/lazy/example.nvim"
if python3 "${repo_root}/scripts/prepare-e2e-fixture.py" \
  --lock "$lock" --data-home "$data_home" --installed-root "${tmpdir}/installed" >/dev/null 2>&1; then
  echo "fixture preparation accepted the wrong plugin revision" >&2
  exit 1
fi

echo "prepared E2E fixture contracts passed"
