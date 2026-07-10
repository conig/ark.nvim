#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d /tmp/ark-performance-summary.XXXXXX)
trap 'rm -rf -- "${tmpdir}"' EXIT INT TERM

printf '%s\n' '{"schema_version":1,"events":{"probe":{"minimum_samples":3,"p95_budget_ms":5,"max_budget_ms":8,"noise_tolerance_percent":10}}}' >"${tmpdir}/budgets.json"
printf '%s\n' '{"schema_version":1,"events":{}}' >"${tmpdir}/baseline.json"
for value in 1 2 3; do
  printf '{"schema_version":1,"event":"probe","condition":"warm","fixture":"tiny","value_ms":%s}\n' "$value" >>"${tmpdir}/samples.ndjson"
done

python3 "${repo_root}/scripts/summarize-performance.py" \
  --samples "${tmpdir}/samples.ndjson" \
  --budgets "${tmpdir}/budgets.json" \
  --baseline "${tmpdir}/baseline.json" \
  --output "${tmpdir}/summary.json" >/dev/null
python3 -c 'import json,sys; report=json.load(open(sys.argv[1])); assert report["status"] == "pass"; assert report["events"]["probe"]["p95_ms"] == 3' "${tmpdir}/summary.json"

if python3 "${repo_root}/scripts/summarize-performance.py" \
  --samples "${tmpdir}/missing.ndjson" \
  --budgets "${tmpdir}/budgets.json" \
  --baseline "${tmpdir}/baseline.json" >/dev/null 2>&1; then
  echo "performance parser accepted missing samples" >&2
  exit 1
fi

printf 'not-json\n' >"${tmpdir}/malformed.ndjson"
if python3 "${repo_root}/scripts/summarize-performance.py" \
  --samples "${tmpdir}/malformed.ndjson" \
  --budgets "${tmpdir}/budgets.json" \
  --baseline "${tmpdir}/baseline.json" >/dev/null 2>&1; then
  echo "performance parser accepted malformed samples" >&2
  exit 1
fi

echo "performance summary contracts passed"
