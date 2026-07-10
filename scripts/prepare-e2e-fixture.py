#!/usr/bin/env python3

import argparse
import json
import os
import pathlib
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_LOCK = ROOT / "tests" / "e2e" / "fixture-lock.json"


def git_output(*args, cwd=None):
    result = subprocess.run(
        ["git", *args], cwd=cwd, check=True, text=True, capture_output=True
    )
    return result.stdout.strip()


def validate_checkout(path, revision, name):
    if not path.is_dir():
        raise ValueError(f"prepared fixture dependency is not a directory: {path}")
    try:
        actual = git_output("rev-parse", "HEAD", cwd=path)
    except subprocess.CalledProcessError as error:
        raise ValueError(f"prepared fixture dependency is not a Git checkout: {path}") from error
    if actual != revision:
        raise ValueError(
            f"prepared fixture dependency {name} is at {actual}, expected {revision}; "
            "run scripts/prepare-e2e-fixture.py --download with a clean data home"
        )


def prepare_plugin(plugin, lazy_root, installed_root, download):
    name = plugin["name"]
    revision = plugin["revision"]
    target = lazy_root / name

    if target.is_symlink() and not target.exists():
        target.unlink()
    if target.exists() or target.is_symlink():
        validate_checkout(target.resolve(), revision, name)
        return

    source_env = plugin.get("source_env", "")
    source = pathlib.Path(os.environ[source_env]).expanduser() if source_env in os.environ else installed_root / name
    if source.is_dir():
        validate_checkout(source.resolve(), revision, name)
        target.symlink_to(source.resolve(), target_is_directory=True)
        return

    if not download:
        raise ValueError(
            f"missing prepared fixture dependency {name} at {target}; "
            "run scripts/prepare-e2e-fixture.py --download before the test phase"
        )

    subprocess.run(
        ["git", "clone", "--filter=blob:none", "--no-checkout", plugin["repository"], str(target)],
        check=True,
    )
    subprocess.run(["git", "checkout", "--detach", revision], cwd=target, check=True)
    validate_checkout(target, revision, name)


def main():
    parser = argparse.ArgumentParser(description="Prepare the pinned Blink E2E fixture")
    parser.add_argument("--lock", type=pathlib.Path, default=DEFAULT_LOCK)
    parser.add_argument(
        "--data-home",
        type=pathlib.Path,
        default=pathlib.Path(os.environ.get("ARK_TEST_DATA_HOME", "/tmp/arktest-data")),
    )
    parser.add_argument(
        "--installed-root",
        type=pathlib.Path,
        default=pathlib.Path.home() / ".local" / "share" / "nvim" / "lazy",
    )
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()

    manifest = json.loads(args.lock.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 1:
        raise ValueError("unsupported E2E fixture lock schema")
    plugins = manifest.get("plugins")
    if not isinstance(plugins, list) or not plugins:
        raise ValueError("E2E fixture lock has no plugins")

    lazy_root = args.data_home / "nvim" / "lazy"
    lazy_root.mkdir(parents=True, exist_ok=True)
    for plugin in plugins:
        prepare_plugin(plugin, lazy_root, args.installed_root, args.download)
    print(f"prepared {len(plugins)} pinned E2E plugins under {lazy_root}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"E2E fixture preparation failed: {error}", file=sys.stderr)
        sys.exit(2)
