#!/usr/bin/env python3
"""Focused fixtures for the Python 3.10 Cargo dependency scanner."""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-only-workspace-dependencies.py"


def load_scanner():
    spec = importlib.util.spec_from_file_location("workspace_dependency_scanner", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {SCRIPT}")
    scanner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scanner)
    return scanner


class WorkspaceDependencyScannerTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory(prefix="ark-workspace-deps-")
        self.root = Path(self.tempdir.name)
        self.scanner = load_scanner()
        self.scanner.REPO_ROOT = self.root

    def tearDown(self):
        self.tempdir.cleanup()

    def check(self, contents: str) -> list[str]:
        manifest = self.root / "crate/Cargo.toml"
        manifest.parent.mkdir(exist_ok=True)
        manifest.write_text(contents, encoding="utf-8")
        return self.scanner.check_deps(manifest)

    def test_accepts_supported_workspace_inheritance_forms(self):
        errors = self.check(
            """
[dependencies]
inline = { workspace = true, features = ["serde"] }
literal-hash = { package = 'with#hash', workspace = true }
dotted.workspace = true
dotted.features = ["serde"]

[dev-dependencies.nested]
workspace = true
features = ["fixtures"]

[target.'cfg(unix)'.build-dependencies]
target-inline = { workspace = true }

[target.'cfg(target_os = "linux")'.dependencies.target-nested]
workspace = true
"""
        )
        self.assertEqual(errors, [])

    def test_rejects_version_and_direct_dependency_forms(self):
        errors = self.check(
            """
[dependencies]
versioned = "1.2.3"
inline-version = { version = "1.2.3" }
misleading-string = { package = "workspace = true" }
direct-path.path = "../direct-path"
false-workspace.workspace = false

[dev-dependencies.direct-nested]
path = "../direct-nested"

[target.'cfg(unix)'.build-dependencies]
direct-git = { git = "https://example.invalid/repo" }
"""
        )
        rendered = "\n".join(errors)
        for dependency in (
            "versioned",
            "inline-version",
            "misleading-string",
            "direct-path",
            "false-workspace",
            "direct-nested",
            "direct-git",
        ):
            self.assertIn(f"'{dependency}' must use workspace inheritance", rendered)
        self.assertEqual(len(errors), 7)

    def test_nested_workspace_root_does_not_inherit_outer_dependencies(self):
        nested = self.root / "crate/fuzz/Cargo.toml"
        nested.parent.mkdir(parents=True)
        nested.write_text(
            '[package]\nname = "fuzz"\n[dependencies]\nstandalone = "1"\n'
            '[workspace] # independent cargo-fuzz workspace\n',
            encoding="utf-8",
        )
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.scanner.main(), 0)

        self.check('[dependencies]\nordinary = "1"\n')
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(self.scanner.main(), 1)
        self.assertIn("'ordinary' must use workspace inheritance", output.getvalue())
        self.assertNotIn("'standalone'", output.getvalue())


if __name__ == "__main__":
    unittest.main()
