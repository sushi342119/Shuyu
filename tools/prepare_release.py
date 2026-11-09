#!/usr/bin/env python3
"""Validate a release tag against pubspec and extract its user-facing notes."""
from __future__ import annotations

import argparse
from pathlib import Path
import re


def next_version(version: str, build: int) -> tuple[str, int]:
    parts = [int(part) for part in version.split(".")]
    if len(parts) != 3 or any(p < 0 for p in parts):
        raise ValueError("Version segments must be non-negative major.minor.patch integers")
    return f"{parts[0]}.{parts[1]}.{parts[2] + 1}", build + 1


def metadata(root: Path, tag: str | None = None) -> tuple[str, int, str]:
    version = re.search(r"^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$",
                        (root / "pubspec.yaml").read_text(), re.M)
    if version is None or not 0 < int(version[4]) < 2100000000:
        raise ValueError("pubspec.yaml needs a semantic version and a positive Android build number")
    major, minor, patch, build = int(version[1]), int(version[2]), int(version[3]), int(version[4])
    name = f"{major}.{minor}.{patch}"
    dart = (root / "lib/updates/app_updates.dart").read_text()
    # Release builds inject pubspec's values. Defaults are for development/tests
    # and need not be bumped with every release. Still reject a misspelled key
    # or a declaration that cannot receive the injected value.
    injected_version = re.search(
        r"const (?:String\s+)?currentAppVersion\s*=\s*String\.fromEnvironment\(\s*"
        r"'APP_VERSION'\s*,\s*defaultValue:\s*'\d+\.\d+\.\d+'\s*,?\s*\)\s*;", dart, re.S)
    injected_build = re.search(
        r"const (?:int\s+)?currentAppBuild\s*=\s*int\.fromEnvironment\(\s*"
        r"'APP_BUILD'\s*,\s*defaultValue:\s*[1-9]\d*\s*,?\s*\)\s*;", dart, re.S)
    app_version = re.search(r"const (?:String\s+)?currentAppVersion\s*=\s*'([^']+)'\s*;", dart)
    app_build = re.search(r"const (?:int\s+)?currentAppBuild\s*=\s*(\d+)\s*;", dart)
    version_ok = injected_version is not None or (app_version is not None and app_version[1] == name)
    build_ok = injected_build is not None or (app_build is not None and int(app_build[1]) == build)
    if not version_ok or not build_ok:
        raise ValueError("Update the app's version constants together with pubspec.yaml")
    if tag is not None and tag not in {f"v{name}", f"v{name}+{build}"}:
        raise ValueError(f"Tag {tag!r} does not match pubspec version {name}+{build}")
    changelog = (root / "CHANGELOG.md").read_text()
    notes = re.search(rf"^## {re.escape(name)}(?:[ \t][^\n]*)?\n(.*?)(?=^## |\Z)",
                      changelog, re.M | re.S)
    if notes is None or not notes[1].strip():
        raise ValueError(f"CHANGELOG.md needs release notes for {name}")
    return name, build, notes[1].strip() + "\n"


def sync_dart_defaults(root: Path, version: str, build: int, notes: str) -> None:
    dart_path = root / "lib/updates/app_updates.dart"
    if not dart_path.is_file():
        return
    dart = dart_path.read_text()
    dart = re.sub(
        r"(const (?:String\s+)?currentAppVersion\s*=\s*String\.fromEnvironment\(\s*'APP_VERSION'\s*,\s*defaultValue:\s*')[^']+(')",
        rf"\g<1>{version}\2",
        dart,
        count=1,
    )
    dart = re.sub(
        r"(const (?:int\s+)?currentAppBuild\s*=\s*int\.fromEnvironment\(\s*'APP_BUILD'\s*,\s*defaultValue:\s*)[1-9]\d*",
        rf"\g<1>{build}",
        dart,
        count=1,
    )
    escaped_notes = notes.replace("\\", "\\\\").replace("$", r"\$")
    dart = re.sub(
        r"const (?:String\s+)?currentReleaseNotes\s*=\s*r?'''[\s\S]*?'''\s*;",
        lambda _: f"const currentReleaseNotes = '''\n{escaped_notes}''';",
        dart,
        count=1,
    )
    dart_path.write_text(dart)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag")
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--notes", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    version, build, notes = metadata(root, args.tag)
    sync_dart_defaults(root, version, build, notes)
    args.notes.parent.mkdir(parents=True, exist_ok=True)
    args.notes.write_text(notes)
    if args.github_output:
        with args.github_output.open("a") as output:
            output.write(f"version={version}\nbuild={build}\n")
    print(f"Release {version}+{build}; notes: {args.notes}")


if __name__ == "__main__":
    main()

