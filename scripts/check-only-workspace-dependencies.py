#!/usr/bin/env python3
"""
Checks that crate-level Cargo.toml files use workspace dependency inheritance
rather than specifying versions inline. Every dependency must be referenced with
`dep.workspace = true` or `dep = { workspace = true, ... }`.
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEP_SECTIONS = ["dependencies", "dev-dependencies", "build-dependencies"]
SECTION_RE = re.compile(r"^\[(.+)\]$")
ASSIGNMENT_RE = re.compile(r"^([A-Za-z0-9_-]+)\s*=\s*(.+)$")
WORKSPACE_ASSIGNMENT_RE = re.compile(
    r"^([A-Za-z0-9_-]+)\.workspace\s*=\s*(true|false)\s*$"
)
DOTTED_ASSIGNMENT_RE = re.compile(
    r"^([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\s*=\s*(.+)$"
)


def dependency_section(section_name: str) -> tuple[str, str | None] | None:
    for base in DEP_SECTIONS:
        if section_name == base:
            return (base, None)
        if section_name.startswith(f"{base}."):
            return (base, section_name[len(base) + 1 :])

        marker = f".{base}"
        if section_name.startswith("target.") and marker in section_name:
            prefix, suffix = section_name.rsplit(marker, 1)
            rendered = f"{prefix}.{base}"
            return (rendered, suffix.removeprefix(".") or None)
    return None


def strip_comment(line: str) -> str:
    quote = None
    escaped = False
    for index, char in enumerate(line):
        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\" and quote == '"':
                escaped = True
            elif char == quote:
                quote = None
        elif char in {'"', "'"}:
            quote = char
        elif char == "#":
            return line[:index].rstrip()
    return line.rstrip()


def inline_workspace_enabled(value: str) -> bool:
    """Find a top-level `workspace = true` field in an inline table.

    This is deliberately narrower than a TOML parser, but it must not mistake
    text inside package names, feature arrays, or nested values for the
    workspace-inheritance field.
    """
    value = value.strip()
    if not (value.startswith("{") and value.endswith("}")):
        return False

    fields = []
    field_start = 1
    depth = 0
    quote = None
    escaped = False
    for index, char in enumerate(value[1:-1], start=1):
        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\" and quote == '"':
                escaped = True
            elif char == quote:
                quote = None
            continue

        if char in {'"', "'"}:
            quote = char
        elif char in "[{(":
            depth += 1
        elif char in "]})":
            depth = max(0, depth - 1)
        elif char == "," and depth == 0:
            fields.append(value[field_start:index])
            field_start = index + 1
    fields.append(value[field_start:-1])

    return any(
        re.fullmatch(r"(?:workspace|['\"]workspace['\"])\s*=\s*true", field.strip())
        for field in fields
    )


def check_deps(toml_path: Path) -> list[str]:
    rel_path = toml_path.relative_to(REPO_ROOT)
    errors = []
    current: tuple[str, str | None] | None = None
    nested_workspace = False
    section_dependencies: dict[str, bool | None] = {}

    def dependency_error(section_name: str, dependency: str) -> None:
        errors.append(
            f"error: {rel_path} [{section_name}]: "
            f"'{dependency}' must use workspace inheritance"
        )

    def finish_section() -> None:
        nonlocal nested_workspace, section_dependencies
        if current is not None:
            section_name, nested_dep = current
            if nested_dep is not None:
                if not nested_workspace:
                    dependency_error(section_name, nested_dep)
            else:
                for dependency, workspace in section_dependencies.items():
                    if workspace is not True:
                        dependency_error(section_name, dependency)
        nested_workspace = False
        section_dependencies = {}

    with open(toml_path, encoding="utf-8") as f:
        for raw_line in f:
            line = strip_comment(raw_line.strip())
            if not line:
                continue

            section_match = SECTION_RE.fullmatch(line)
            if section_match:
                finish_section()
                current = dependency_section(section_match.group(1))
                continue
            if current is None:
                continue

            section_name, nested_dep = current
            if nested_dep is not None:
                assignment = ASSIGNMENT_RE.fullmatch(line)
                if assignment and assignment.group(1) == "workspace":
                    nested_workspace = assignment.group(2).strip() == "true"
                continue

            workspace_assignment = WORKSPACE_ASSIGNMENT_RE.fullmatch(line)
            if workspace_assignment:
                section_dependencies[workspace_assignment.group(1)] = (
                    workspace_assignment.group(2) == "true"
                )
                continue

            dotted_assignment = DOTTED_ASSIGNMENT_RE.fullmatch(line)
            if dotted_assignment:
                dependency = dotted_assignment.group(1)
                section_dependencies.setdefault(dependency, None)
                continue

            assignment = ASSIGNMENT_RE.fullmatch(line)
            if not assignment:
                continue
            dep_name, value = assignment.groups()
            if not inline_workspace_enabled(value):
                section_dependencies[dep_name] = False
            else:
                section_dependencies[dep_name] = True

    finish_section()
    return errors


def main() -> int:
    crate_tomls = [
        p
        for p in REPO_ROOT.rglob("Cargo.toml")
        if p != REPO_ROOT / "Cargo.toml" and "target" not in p.parts
    ]

    errors = []

    for toml_path in sorted(crate_tomls):
        errors.extend(check_deps(toml_path))

    for error in errors:
        print(error)

    if errors:
        return 1

    print("All crate dependencies use workspace inheritance.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
