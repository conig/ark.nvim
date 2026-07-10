#!/usr/bin/env python3

import argparse
import json
import math
import pathlib
import statistics
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def percentile(values, proportion):
    index = max(0, min(len(values) - 1, math.ceil(len(values) * proportion) - 1))
    return values[index]


def read_samples(path):
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f"performance sample file is missing or empty: {path}")
    records = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"malformed sample JSON on line {line_number}: {error}") from error
        if not isinstance(record, dict) or record.get("schema_version") != 1:
            raise ValueError(f"invalid sample schema on line {line_number}")
        if not isinstance(record.get("event"), str) or not record["event"]:
            raise ValueError(f"missing sample event on line {line_number}")
        value = record.get("value_ms")
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise ValueError(f"invalid value_ms on line {line_number}")
        records.append(record)
    return records


def summarize(records, budgets, baseline):
    expected = budgets.get("events")
    if budgets.get("schema_version") != 1 or not isinstance(expected, dict) or not expected:
        raise ValueError("invalid or empty performance budget manifest")
    baseline_events = baseline.get("events", {})
    grouped = {}
    for record in records:
        event = record["event"]
        if event not in expected:
            raise ValueError(f"sample references event without a budget: {event}")
        grouped.setdefault(event, []).append(float(record["value_ms"]))

    failures = []
    results = {}
    for event, budget in expected.items():
        values = sorted(grouped.get(event, []))
        minimum = int(budget["minimum_samples"])
        if len(values) < minimum:
            failures.append(f"{event}: expected at least {minimum} samples, got {len(values)}")
            continue
        result = {
            "samples": len(values),
            "p50_ms": statistics.median(values),
            "p95_ms": percentile(values, 0.95),
            "max_ms": values[-1],
            "condition": next(record["condition"] for record in records if record["event"] == event),
            "fixture": next(record["fixture"] for record in records if record["event"] == event),
        }
        p95_limit = float(budget["p95_budget_ms"])
        max_limit = float(budget["max_budget_ms"])
        if result["p95_ms"] > p95_limit:
            failures.append(f"{event}: p95 {result['p95_ms']:.3f}ms exceeds {p95_limit:.3f}ms")
        if result["max_ms"] > max_limit:
            failures.append(f"{event}: max {result['max_ms']:.3f}ms exceeds {max_limit:.3f}ms")

        prior = baseline_events.get(event)
        if isinstance(prior, dict) and isinstance(prior.get("p95_ms"), (int, float)):
            tolerance = float(budget.get("noise_tolerance_percent", 0)) / 100
            noise_floor = float(budget.get("baseline_noise_floor_ms", 0))
            prior_p95 = float(prior["p95_ms"])
            baseline_limit = max(prior_p95 * (1 + tolerance), prior_p95 + noise_floor)
            result["baseline_p95_ms"] = float(prior["p95_ms"])
            result["baseline_limit_ms"] = baseline_limit
            if result["p95_ms"] > baseline_limit:
                failures.append(
                    f"{event}: p95 {result['p95_ms']:.3f}ms exceeds noisy baseline limit {baseline_limit:.3f}ms"
                )
        results[event] = result

    return {
        "schema_version": 1,
        "status": "pass" if not failures else "fail",
        "sample_count": len(records),
        "events": results,
        "failures": failures,
    }


def main():
    parser = argparse.ArgumentParser(description="Validate and summarize Ark performance NDJSON")
    parser.add_argument("--samples", type=pathlib.Path, required=True)
    parser.add_argument("--budgets", type=pathlib.Path, default=ROOT / "tests" / "performance-budgets.json")
    parser.add_argument("--baseline", type=pathlib.Path, default=ROOT / "tests" / "performance-baseline.json")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()

    report = summarize(read_samples(args.samples), read_json(args.budgets), read_json(args.baseline))
    output = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
    print(output, end="")
    if report["status"] != "pass":
        raise ValueError("; ".join(report["failures"]))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"performance summary error: {error}", file=sys.stderr)
        sys.exit(2)
