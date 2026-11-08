#!/usr/bin/env python3
"""Static sanity checks that do not need a Swift toolchain.

This is not a compiler and it does not pretend to be one. It catches the class of
mistake that is easy to make when writing Swift on Windows and tedious to find on a
Mac: unbalanced braces / parens / brackets, and a malformed Info.plist.

Usage:  python Tools/sanity_check.py
"""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # RecorderApp/


def scan_balanced(src: str) -> list[str]:
    """Return human-readable errors. Understands comments, strings, interpolation."""
    frames: list[dict] = [{"kind": "code", "interp": False}]
    stack: list[tuple[str, int]] = []
    errors: list[str] = []
    i, n, line = 0, len(src), 1

    while i < n:
        ch = src[i]
        frame = frames[-1]

        if ch == "\n":
            line += 1
            i += 1
            continue

        if frame["kind"] == "code":
            if src.startswith("//", i):
                j = src.find("\n", i)
                i = n if j == -1 else j
                continue
            if src.startswith("/*", i):
                j = src.find("*/", i + 2)
                end = n if j == -1 else j + 2
                line += src.count("\n", i, end)
                i = end
                continue
            if src.startswith('"""', i):
                frames.append({"kind": "multistring"})
                i += 3
                continue
            if ch == '"':
                frames.append({"kind": "string"})
                i += 1
                continue
            if ch in "({[":
                stack.append((ch, line))
                i += 1
                continue
            if ch in ")}]":
                pairs = {"}": "{", ")": "(", "]": "["}
                if not stack:
                    errors.append(f"line {line}: unmatched '{ch}'")
                else:
                    opener, opened_at = stack.pop()
                    if opener != pairs[ch]:
                        errors.append(
                            f"line {line}: '{ch}' closes '{opener}' opened at line {opened_at}"
                        )
                # Leaving an interpolation goes back to the string it lives in.
                if frames[-1]["kind"] == "code" and frames[-1]["interp"]:
                    if len(stack) == frames[-1]["base"]:
                        frames.pop()
                i += 1
                continue
            i += 1
            continue

        if frame["kind"] == "string":
            if ch == "\\":
                if src.startswith("\\(", i):
                    stack.append(("(", line))
                    # `base` is the depth *before* the interpolation paren, so that the
                    # `)` which returns depth to that level also ends the interpolation.
                    frames.append({"kind": "code", "interp": True, "base": len(stack) - 1})
                    i += 2
                    continue
                i += 2
                continue
            if ch == '"':
                frames.pop()
                i += 1
                continue
            i += 1
            continue

        if frame["kind"] == "multistring":
            if src.startswith('"""', i):
                frames.pop()
                i += 3
                continue
            i += 1
            continue

    for opener, opened_at in stack:
        errors.append(f"unclosed '{opener}' opened at line {opened_at}")

    return errors


def check_swift() -> tuple[int, int, list[str]]:
    files = sorted(ROOT.glob("Sources/**/*.swift")) + sorted(ROOT.glob("Tests/**/*.swift"))
    failures: list[str] = []
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError as exc:
            failures.append(f"{path.relative_to(ROOT)}: not valid UTF-8 ({exc})")
            continue
        for error in scan_balanced(text):
            failures.append(f"{path.relative_to(ROOT)}: {error}")
        if not text.endswith("\n"):
            failures.append(f"{path.relative_to(ROOT)}: missing trailing newline")
    return len(files), 0, failures


def check_plist() -> list[str]:
    path = ROOT / "Sources/Resources/Info.plist"
    try:
        with path.open("rb") as handle:
            data = plistlib.load(handle)
    except Exception as exc:  # noqa: BLE001 - any parse failure is the finding
        return [f"Sources/Resources/Info.plist: {exc}"]

    required = [
        "NSMicrophoneUsageDescription",
        "UIBackgroundModes",
        "CFBundleIdentifier",
        "CFBundleExecutable",
    ]
    problems = [f"Info.plist: missing key {key}" for key in required if key not in data]
    if "audio" not in data.get("UIBackgroundModes", []):
        problems.append("Info.plist: UIBackgroundModes must contain 'audio'")
    if not data.get("NSMicrophoneUsageDescription"):
        problems.append("Info.plist: microphone usage string is empty")
    return problems


def main() -> int:
    count, _, swift_failures = check_swift()
    plist_failures = check_plist()
    failures = swift_failures + plist_failures

    print(f"Swift files checked : {count}")
    print(f"Info.plist          : {'ok' if not plist_failures else 'FAILED'}")
    print(f"Structural issues   : {len(failures)}")
    for failure in failures:
        print(f"  - {failure}")

    if failures:
        return 1
    print("\nNo structural problems found. This does NOT mean it compiles — run `xcodebuild` on the Mac.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
