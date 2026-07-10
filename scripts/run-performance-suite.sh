#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_root="${1:-${repo_root}/artifacts/performance/$(date -u +%Y%m%dT%H%M%SZ)}"
samples="${output_root}/samples.ndjson"
transcript="${output_root}/run.log"
budgets="${repo_root}/tests/performance-budgets.json"

mkdir -p "$output_root"
: >"$samples"
: >"$transcript"

while IFS= read -r test_path; do
  test_name=$(basename -- "$test_path")
  runs=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["benchmarks"][sys.argv[2]]["runs"])' \
    "$budgets" "$test_name")
  for run in $(seq 1 "$runs"); do
    printf '\n==> benchmark %s run %s/%s\n' "$test_name" "$run" "$runs" | tee -a "$transcript"
    ARK_PERF_SAMPLES_FILE="$samples" \
      "$repo_root/scripts/run-full-suite.sh" \
      --skip-rust --skip-clippy --tier performance --filter "$test_name" --e2e-timeout 180 \
      2>&1 | tee -a "$transcript"
  done
done < <(python3 "$repo_root/scripts/test-manifest.py" list --tier performance)

python3 "$repo_root/scripts/summarize-performance.py" \
  --samples "$samples" --output "$output_root/summary.json" | tee -a "$transcript"

echo "performance artifacts: $output_root"
