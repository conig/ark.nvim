#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
probe_script="$repo_root/tests/e2e/startup_timing_probe.lua"
tmp_root=$(mktemp -d /tmp/ark-startup-cwd-parity.XXXXXX)
data_home="$tmp_root/data-home"
home_cwd="${ARKTEST_HOME_CWD:-$HOME}"
subdir_cwd="$tmp_root/subdir"
ratio_limit="${ARK_STARTUP_PARITY_RATIO_LIMIT:-2.5}"
delta_limit_ms="${ARK_STARTUP_PARITY_DELTA_MS:-300}"
keep_artifacts="${ARK_STARTUP_PARITY_KEEP_ARTIFACTS:-0}"

cleanup() {
  local status="${1:-$?}"
  if [[ "$status" -eq 0 && "$keep_artifacts" -eq 0 ]]; then
    rm -rf -- "$tmp_root"
  else
    printf 'startup parity artifacts: %s\n' "$tmp_root" >&2
  fi
  exit "$status"
}
trap 'cleanup $?' EXIT INT TERM

mkdir -p "$data_home" "$subdir_cwd"

home_has_root_marker() {
  local marker=""
  for marker in .git renv.lock DESCRIPTION; do
    if [[ -e "$home_cwd/$marker" ]]; then
      return 0
    fi
  done

  find "$home_cwd" -maxdepth 1 -name '*.Rproj' -print -quit | grep -q .
}

extract_startup_elapsed_ms() {
  local log_path="$1"
  perl -ne '
    if (/startup_elapsed_ms = ([0-9.]+)/) {
      print "$1\n";
      $found = 1;
      exit 0;
    }

    END {
      exit($found ? 0 : 1);
    }
  ' "$log_path"
}

run_probe() {
  local label="$1"
  local cwd="$2"
  local run_tmpdir="$3"

  mkdir -p "$run_tmpdir"
  if ! (
    cd "$cwd" &&
      ARK_TEST_RUN_ID="$label" \
      ARK_TEST_TMPDIR="$run_tmpdir" \
      ARK_TEST_DATA_HOME="$data_home" \
      "$repo_root/scripts/run-e2e-test.sh" --init NONE --keep-artifacts "$probe_script"
  ) >/dev/null; then
    cat "$run_tmpdir/nvim.log" >&2 || true
    return 1
  fi

  extract_startup_elapsed_ms "$run_tmpdir/nvim.log"
}

measure_case() {
  local label="$1"
  local cwd="$2"
  local first_ms=""
  local second_ms=""

  first_ms=$(run_probe "${label}_1" "$cwd" "$tmp_root/${label}-1")
  second_ms=$(run_probe "${label}_2" "$cwd" "$tmp_root/${label}-2")

  awk -v first="$first_ms" -v second="$second_ms" 'BEGIN {
    if (first <= second) {
      print first
    } else {
      print second
    }
  }'
}

if home_has_root_marker; then
  printf 'HOME contains a project root marker; startup parity test requires a non-project home cwd: %s\n' "$home_cwd" >&2
  exit 2
fi

# Reproduce the real user-facing shape: unnamed startup buffers from a large
# non-project cwd should not be dramatically slower than the same startup from
# a small non-project subdir once the pane-side runtime is already current.
run_probe "parity_prewarm" "$repo_root" "$tmp_root/prewarm" >/dev/null

home_ms=$(measure_case "home" "$home_cwd")
subdir_ms=$(measure_case "subdir" "$subdir_cwd")

ratio=$(awk -v home="$home_ms" -v subdir="$subdir_ms" 'BEGIN {
  if (subdir <= 0) {
    print "inf"
  } else {
    printf "%.6f", home / subdir
  }
}')
delta_ms=$(awk -v home="$home_ms" -v subdir="$subdir_ms" 'BEGIN {
  printf "%.6f", home - subdir
}')

printf 'startup parity home_ms=%s subdir_ms=%s ratio=%s delta_ms=%s\n' \
  "$home_ms" "$subdir_ms" "$ratio" "$delta_ms"

if awk -v home="$home_ms" \
  -v subdir="$subdir_ms" \
  -v ratio_limit="$ratio_limit" \
  -v delta_limit_ms="$delta_limit_ms" \
  'BEGIN {
    if (subdir <= 0) {
      exit 1
    }

    if (home > (subdir * ratio_limit) && (home - subdir) > delta_limit_ms) {
      exit 1
    }

    exit 0
  }'
then
  exit 0
fi

printf 'startup parity exceeded limits: ratio_limit=%s delta_limit_ms=%s\n' \
  "$ratio_limit" "$delta_limit_ms" >&2
exit 1
