#!/usr/bin/env python3
"""Verify the intentional Watch, orientation, Mach-O, and FLEX changes."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def inventory(root: Path) -> dict[str, dict[str, object]]:
    result: dict[str, dict[str, object]] = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if path.is_symlink():
            result[relative] = {"kind": "symlink", "target": os.readlink(path), "mode": mode}
        elif path.is_file():
            result[relative] = {"kind": "file", "sha256": digest(path), "mode": mode}
    return result


def snapshot(app: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(inventory(app), indent=2, sort_keys=True), encoding="utf-8")


def verify(snapshot_path: Path, app: Path, executable: str) -> None:
    before = json.loads(snapshot_path.read_text(encoding="utf-8"))
    after = inventory(app)
    before_paths = set(before)
    after_paths = set(after)

    removed = sorted(before_paths - after_paths)
    added = sorted(after_paths - before_paths)
    changed = sorted(path for path in before_paths & after_paths if before[path] != after[path])

    invalid_removed = [path for path in removed if not path.startswith("Watch/")]
    invalid_added = [
        path
        for path in added
        if path != "Frameworks/FLEXLoader.dylib"
        and not path.startswith("Frameworks/FLEX.framework/")
    ]
    allowed_changed = {executable, "Info.plist"}
    invalid_changed = [path for path in changed if path not in allowed_changed]

    errors: list[str] = []
    if invalid_removed:
        errors.append(f"unexpected removed paths: {invalid_removed}")
    if invalid_added:
        errors.append(f"unexpected added paths: {invalid_added}")
    if invalid_changed:
        errors.append(f"unexpected changed paths: {invalid_changed}")
    if not removed or any(not path.startswith("Watch/") for path in removed):
        errors.append("Watch app removal was not cleanly observed")
    if executable not in changed:
        errors.append("main executable modification was not observed")
    if "Info.plist" not in changed:
        errors.append("iPhone landscape capability update was not observed")
    if "Frameworks/FLEXLoader.dylib" not in added:
        errors.append("FLEXLoader.dylib was not added")
    if not any(path.startswith("Frameworks/FLEX.framework/") for path in added):
        errors.append("FLEX.framework was not added")

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)

    print(f"removed_watch_entries={len(removed)}")
    print(f"added_flex_entries={len(added)}")
    print(f"modified_existing_files={changed}")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument("app", type=Path)
    snapshot_parser.add_argument("output", type=Path)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("snapshot", type=Path)
    verify_parser.add_argument("app", type=Path)
    verify_parser.add_argument("executable")
    arguments = parser.parse_args()

    if arguments.command == "snapshot":
        snapshot(arguments.app, arguments.output)
    else:
        verify(arguments.snapshot, arguments.app, arguments.executable)


if __name__ == "__main__":
    main()
