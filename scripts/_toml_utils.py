"""
Tiny TOML helpers shared by release and toolchain verification scripts.

The leading underscore marks this as an internal module: don't run it directly,
import from it.
"""

import json
import re
from pathlib import Path

SECTION_RE = re.compile(r"^\[(.+)\]$")
KEY_VALUE_RE = re.compile(r'^([A-Za-z0-9_-]+)\s*=\s*"([^"]+)"\s*$')
ARRAY_KEY_VALUE_RE = re.compile(r"^([A-Za-z0-9_-]+)\s*=\s*(\[.*\])\s*$")


def find_string_value(path: Path, section_name: str, key_name: str) -> str | None:
    current_section = None

    with open(path, encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue

            section_match = SECTION_RE.fullmatch(line)
            if section_match:
                current_section = section_match.group(1)
                continue

            if current_section != section_name:
                continue

            key_value_match = KEY_VALUE_RE.fullmatch(line)
            if key_value_match and key_value_match.group(1) == key_name:
                return key_value_match.group(2)

    return None


def find_string_array(
    path: Path, section_name: str, key_name: str
) -> list[str] | None:
    """Read the small one-line string arrays used by Ark's toolchain files.

    This intentionally is not a general TOML parser. It keeps release tooling
    compatible with the Python 3.10 shipped by Ubuntu 22.04 without adding an
    ambient `tomli` dependency.
    """
    current_section = None

    with open(path, encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue

            section_match = SECTION_RE.fullmatch(line)
            if section_match:
                current_section = section_match.group(1)
                continue

            if current_section != section_name:
                continue

            array_match = ARRAY_KEY_VALUE_RE.fullmatch(line)
            if not array_match or array_match.group(1) != key_name:
                continue

            try:
                value = json.loads(array_match.group(2))
            except json.JSONDecodeError:
                return None
            if not isinstance(value, list) or not all(
                isinstance(item, str) for item in value
            ):
                return None
            return value

    return None
