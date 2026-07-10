#!/usr/bin/env python3

import argparse
import fnmatch
import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "tests" / "test-manifest.json"
E2E_DIR = ROOT / "tests" / "e2e"
TIERS = {"unit", "fast", "serial-integration", "full-tui", "performance", "soak"}
VIRTUAL_TIERS = {"required", "integration", "full"}
REQUIRED_FIELDS = {
    "contract": str,
    "owner": str,
    "layer": str,
    "dependencies": list,
    "typical_runtime": str,
    "flake_policy": str,
    "mutates_shared_session": bool,
}


def load_manifest(path):
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def matches(rule, name, text):
    names = rule.get("names", [])
    globs = rule.get("globs", [])
    marker = rule.get("content_contains")
    return (
        name in names
        or any(fnmatch.fnmatch(name, pattern) for pattern in globs)
        or (isinstance(marker, str) and marker in text)
    )


def resolve(manifest):
    defaults = manifest.get("defaults", {})
    excluded = manifest.get("exclude", {})
    rules = manifest.get("rules", [])
    overrides = manifest.get("overrides", {})
    records = []

    for path in sorted(E2E_DIR.glob("*.lua")):
        name = path.name
        if name in excluded:
            continue
        text = path.read_text(encoding="utf-8")
        record = dict(defaults)
        record.update({"name": name, "path": str(path)})
        for rule in rules:
            if matches(rule, name, text):
                record.update({key: value for key, value in rule.items() if key not in {
                    "names", "globs", "content_contains"
                }})
                break
        record.update(overrides.get(name, {}))
        records.append(record)
    return records


def validate(manifest, records):
    errors = []
    actual = {path.name for path in E2E_DIR.glob("*.lua")}
    excluded = manifest.get("exclude", {})
    resolved = {record["name"] for record in records}

    for name, reason in excluded.items():
        if name not in actual:
            errors.append(f"excluded test does not exist: {name}")
        if not isinstance(reason, str) or not reason.strip():
            errors.append(f"excluded test has no reason: {name}")
    for rule in manifest.get("rules", []):
        for name in rule.get("names", []):
            if name not in actual:
                errors.append(f"test rule references missing test: {name}")
    if actual != resolved | set(excluded):
        missing = actual - resolved - set(excluded)
        extra = resolved | set(excluded) - actual
        errors.extend(f"unclassified test: {name}" for name in sorted(missing))
        errors.extend(f"manifest references missing test: {name}" for name in sorted(extra))

    for record in records:
        if record.get("tier") not in TIERS:
            errors.append(f"invalid tier for {record['name']}: {record.get('tier')}")
        if record.get("serial") is not True:
            errors.append(f"E2E must be declared serial: {record['name']}")
        for field, expected_type in REQUIRED_FIELDS.items():
            value = record.get(field)
            if not isinstance(value, expected_type):
                errors.append(
                    f"{field} must be {expected_type.__name__}: {record['name']}"
                )
            elif expected_type is str and not value.strip():
                errors.append(f"{field} must not be empty: {record['name']}")

    for journey, name in manifest.get("critical_journeys", {}).items():
        if name not in resolved:
            errors.append(f"critical journey {journey} references unavailable test: {name}")

    if errors:
        raise ValueError("\n".join(errors))


def selected(records, tier):
    if tier == "full":
        return records
    if tier == "required":
        return [record for record in records if record["tier"] in {"unit", "fast"}]
    if tier == "integration":
        return [record for record in records if record["tier"] in {
            "serial-integration", "full-tui"
        }]
    return [record for record in records if record["tier"] == tier]


def main():
    parser = argparse.ArgumentParser(description="Validate and query Ark test tiers")
    parser.add_argument("command", choices=("validate", "list", "describe"))
    parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--tier", default="full")
    parser.add_argument("--format", choices=("paths", "tsv", "json"), default="paths")
    args = parser.parse_args()

    manifest = load_manifest(args.manifest)
    records = resolve(manifest)
    validate(manifest, records)
    if args.command == "validate":
        print(f"validated {len(records)} E2E tests across {len(TIERS)} tiers")
        return

    if args.tier not in VIRTUAL_TIERS and args.tier not in TIERS:
        raise ValueError(f"unknown tier: {args.tier}")
    records = selected(records, args.tier)
    if args.command == "describe" or args.format == "json":
        json.dump(records, sys.stdout, indent=2)
        print()
    elif args.format == "tsv":
        for record in records:
            print("\t".join((
                record["path"],
                record["tier"],
                str(record.get("init", "NONE")),
                "1" if record.get("open_r_buffer") else "0",
                str(record.get("cwd") or "-"),
                record["contract"],
                ",".join(record["dependencies"]),
            )))
    else:
        for record in records:
            print(record["path"])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"test manifest error: {error}", file=sys.stderr)
        sys.exit(2)
