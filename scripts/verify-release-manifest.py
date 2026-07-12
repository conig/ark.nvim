#!/usr/bin/env python3

import argparse
import json
import pathlib
import re
import subprocess
import sys

from _toml_utils import find_string_array, find_string_value


ROOT = pathlib.Path(__file__).resolve().parent.parent


def fail(message: str) -> None:
    raise SystemExit(f"release manifest check failed: {message}")


def load_manifest() -> dict:
    path = ROOT / "release-manifest.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as err:
        fail(f"cannot load {path}: {err}")
    if not isinstance(value, dict):
        fail("top-level value must be an object")
    return value


def validate_source(manifest: dict) -> None:
    version = manifest.get("product_version")
    if not isinstance(version, str) or not re.fullmatch(
        r"(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)){2}(?:-[0-9A-Za-z.-]+)?",
        version,
    ):
        fail(f"product_version is not a supported semantic version: {version!r}")

    expected_tag = f"v{version}"
    if manifest.get("release_tag") != expected_tag:
        fail(f"release_tag must be {expected_tag!r}")

    channel = manifest.get("release_channel")
    if channel not in {"alpha", "beta", "stable"}:
        fail("release_channel must be one of: alpha, beta, stable")
    prerelease = version.partition("-")[2]
    if channel == "stable" and prerelease:
        fail("stable release_channel cannot use a prerelease product_version")
    prerelease_channel = prerelease.split(".", 1)[0]
    if channel in {"alpha", "beta"} and prerelease_channel != channel:
        fail(f"{channel} release_channel requires a -{channel} product_version")

    release_notes = ROOT / "docs" / "releases" / f"{expected_tag}.md"
    if not release_notes.is_file():
        fail(f"release notes are missing: {release_notes.relative_to(ROOT)}")

    compatibility = manifest.get("compatibility")
    if not isinstance(compatibility, dict):
        fail("compatibility must be an object")
    if compatibility.get("policy") != "exact-product-version":
        fail("the first release series must use exact-product-version compatibility")
    if compatibility.get("bridge_schema") != "v1":
        fail("compatibility.bridge_schema must match the current v1 bridge")

    targets = manifest.get("release_targets")
    if not isinstance(targets, list) or not targets:
        fail("at least one release target is required")
    identities: set[tuple[str, str]] = set()
    assets: set[str] = set()
    for target in targets:
        if not isinstance(target, dict):
            fail("each release target must be an object")
        identity = (target.get("os"), target.get("arch"))
        if not all(isinstance(part, str) and part for part in identity):
            fail(f"target has an invalid os/arch identity: {target!r}")
        if identity in identities:
            fail(f"duplicate release target: {identity!r}")
        identities.add(identity)

        asset = target.get("asset")
        checksum_asset = target.get("checksum_asset")
        if not isinstance(asset, str) or version not in asset:
            fail(f"target asset must contain product version {version}: {asset!r}")
        if checksum_asset != f"{asset}.sha256":
            fail(f"checksum asset must be {asset}.sha256")
        if asset in assets:
            fail(f"duplicate release asset: {asset}")
        assets.add(asset)

    default_members = find_string_array(
        ROOT / "Cargo.toml", "workspace", "default-members"
    )
    if default_members != ["crates/ark-lsp"]:
        fail("Cargo default-members must contain only the ark-lsp product root")

    channel = find_string_value(
        ROOT / "rust-toolchain.toml", "toolchain", "channel"
    )
    if not isinstance(channel, str) or not re.fullmatch(r"\d+\.\d+\.\d+", channel):
        fail("rust-toolchain.toml must pin an exact stable release")

    rustfmt_channel = find_string_value(
        ROOT / "rustfmt-toolchain.toml", "toolchain", "channel"
    )
    if not isinstance(rustfmt_channel, str) or not re.fullmatch(
        r"nightly-\d{4}-\d{2}-\d{2}", rustfmt_channel
    ):
        fail("rustfmt-toolchain.toml must pin an exact nightly date")


def validate_artifact(manifest: dict, artifact: pathlib.Path) -> None:
    try:
        output = subprocess.run(
            [str(artifact), "--version", "--json"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        metadata = json.loads(output)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as err:
        fail(f"cannot inspect release artifact {artifact}: {err}")

    expected_target = next(
        (
            target
            for target in manifest["release_targets"]
            if target["rust_target"] == metadata.get("target")
        ),
        None,
    )
    if metadata.get("product_version") != manifest["product_version"]:
        fail(
            "artifact product version does not match manifest: "
            f"{metadata.get('product_version')!r}"
        )
    if metadata.get("bridge_schema") != manifest["compatibility"]["bridge_schema"]:
        fail("artifact bridge schema does not match manifest")
    if metadata.get("profile") != "release":
        fail(f"artifact is not an optimized release build: {metadata.get('profile')!r}")
    if expected_target is None:
        fail(f"artifact target is not release-tier: {metadata.get('target')!r}")


def validate_publish_ready(manifest: dict) -> None:
    version = manifest["product_version"]
    notes_path = ROOT / "docs" / "releases" / f"v{version}.md"
    notes = notes_path.read_text(encoding="utf-8")
    first_line = next(iter(notes.splitlines()), "")
    if "(planned)" in first_line.lower() or "has not yet been tagged or published" in notes:
        fail(f"release notes are still marked planned: {notes_path.relative_to(ROOT)}")

    changelog_path = ROOT / "CHANGELOG.md"
    changelog = changelog_path.read_text(encoding="utf-8")
    if (
        f"## {version} - Planned" in changelog
        or "This version has not been tagged or published" in changelog
    ):
        fail(f"changelog still marks {version} as planned")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact", type=pathlib.Path)
    parser.add_argument("--for-publish", action="store_true")
    args = parser.parse_args()

    manifest = load_manifest()
    validate_source(manifest)
    if args.for_publish:
        validate_publish_ready(manifest)
    if args.artifact is not None:
        validate_artifact(manifest, args.artifact.resolve())
    print("release manifest check passed")


if __name__ == "__main__":
    main()
