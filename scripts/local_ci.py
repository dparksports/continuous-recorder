#!/usr/bin/env python3
"""Local CI — every check that does not require a Swift toolchain.

This is what runs on the developer machine and in the `checks` CI job. It cannot
tell you the Swift compiles; that is the macOS `build` job's job. What it does tell
you: the Swift is structurally sound, the plist and YAML parse, the model still
produces the numbers the docs quote, every markdown link resolves, the SVGs are
valid XML, the version is consistent, and no obvious credential leaked.

Run:  python scripts/local_ci.py
Exit: 0 when every check passes, 1 otherwise.
"""

from __future__ import annotations

import importlib.util
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ElementTree
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAILURES: list[str] = []
WARNINGS: list[str] = []

TEXT_SUFFIXES = {".swift", ".py", ".md", ".yml", ".yaml", ".plist", ".sh", ".ps1"}


def note(status: str, name: str, detail: str = "") -> None:
    line = f"  {status:<4} {name}"
    if detail:
        line += f"  — {detail}"
    print(line)


def check(name: str, problems: list[str], ok_detail: str = "") -> None:
    if problems:
        FAILURES.extend(f"{name}: {problem}" for problem in problems)
        note("FAIL", name, f"{len(problems)} problem(s)")
        for problem in problems:
            print(f"         · {problem}")
    else:
        note("PASS", name, ok_detail)


# --------------------------------------------------------------------------- checks


def swift_structure() -> list[str]:
    script = ROOT / "RecorderApp" / "Tools" / "sanity_check.py"
    result = subprocess.run(
        [sys.executable, str(script)],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    if result.returncode == 0:
        tail = result.stdout.strip().splitlines()
        return [] if not tail else []
    lines = (result.stdout + result.stderr).strip().splitlines()
    return [line.strip() for line in lines if line.strip().startswith("-")] or [
        (result.stderr or result.stdout).strip()[:400]
    ]


def info_plist() -> list[str]:
    path = ROOT / "RecorderApp" / "Sources" / "Resources" / "Info.plist"
    try:
        with path.open("rb") as handle:
            data = plistlib.load(handle)
    except Exception as exc:  # noqa: BLE001
        return [f"cannot parse: {exc}"]

    problems: list[str] = []
    for key in ("NSMicrophoneUsageDescription", "NSCameraUsageDescription",
                "UIBackgroundModes", "CFBundleIdentifier"):
        if key not in data:
            problems.append(f"missing key {key}")
    if "audio" not in data.get("UIBackgroundModes", []):
        problems.append("UIBackgroundModes must contain audio")
    for key in ("NSMicrophoneUsageDescription", "NSCameraUsageDescription"):
        if key in data and len(str(data[key])) < 20:
            problems.append(f"{key} is too short to be a useful prompt")
    return problems


def yaml_files() -> list[str]:
    try:
        import yaml  # noqa: PLC0415 - optional dependency
    except ImportError:
        WARNINGS.append("pyyaml not installed; YAML files were not validated")
        note("SKIP", "yaml parse", "pyyaml missing")
        return []

    problems: list[str] = []
    for path in (ROOT / "RecorderApp" / "project.yml",
                 ROOT / ".github" / "workflows" / "ci.yml"):
        try:
            with path.open(encoding="utf-8") as handle:
                yaml.safe_load(handle)
        except Exception as exc:  # noqa: BLE001
            problems.append(f"{path.relative_to(ROOT)}: {exc}")
    return problems


def model_invariants() -> list[str]:
    path = ROOT / "RecorderApp" / "Tools" / "runtime_estimate.py"
    spec = importlib.util.spec_from_file_location("runtime_estimate", path)
    if spec is None or spec.loader is None:
        return ["cannot load runtime_estimate.py"]
    model = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(model)

    def watt_hours(fragment: str) -> float:
        for name, value in model.DEVICES.items():
            if fragment in name:
                return value
        raise KeyError(fragment)

    def typical(scenarios: list, index: int) -> float:
        return model.scenario_watts(scenarios[index][1])[1]

    problems: list[str] = []
    usable_11 = model.usable_wh(watt_hours("11"))
    usable_13 = model.usable_wh(watt_hours("13"))

    audio_w = typical(model.AUDIO_SCENARIOS, 0)
    video_w = typical(model.VIDEO_SCENARIOS, 0)

    audio_h = model.hours(usable_11, audio_w)
    video_h = model.hours(usable_11, video_w)

    if not audio_w < video_w:
        problems.append(f"audio ({audio_w:.2f} W) should draw less than video ({video_w:.2f} W)")
    if not 80 <= audio_h <= 160:
        problems.append(f"audio runtime {audio_h:.1f} h is outside the documented 80–160 h band")
    if not 10 <= video_h <= 25:
        problems.append(f"video runtime {video_h:.1f} h is outside the documented 10–25 h band")
    if model.hours(usable_13, video_w) <= video_h:
        problems.append("13-inch runtime must exceed 11-inch runtime")
    if model.streaming_mb_per_hour(96, 1) <= model.streaming_mb_per_hour(48, 1):
        problems.append("storage per hour must grow with bitrate")

    return problems


def markdown_links() -> list[str]:
    problems: list[str] = []
    link_pattern = re.compile(r"\]\(([^)\s]+)")

    for path in sorted(ROOT.glob("**/*.md")):
        if ".zwork" in path.parts or "build" in path.parts:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for target in link_pattern.findall(text):
            if re.match(r"^[a-z]+://", target) or target.startswith(("#", "mailto:")):
                continue
            clean = target.split("#", 1)[0]
            if not clean:
                continue
            resolved = (path.parent / clean).resolve()
            if not resolved.exists():
                problems.append(f"{path.relative_to(ROOT)} → {target} does not exist")
    return problems


def svg_assets() -> list[str]:
    problems: list[str] = []
    for path in sorted((ROOT / "assets").glob("*.svg")):
        try:
            ElementTree.parse(path)
        except ElementTree.ParseError as exc:
            problems.append(f"{path.name}: {exc}")
        png = path.with_suffix(".png")
        if not png.exists() or png.stat().st_size < 10_000:
            problems.append(f"{path.name}: missing or suspiciously small PNG export")
    if not list((ROOT / "assets").glob("*.svg")):
        problems.append("no infographics found in assets/")
    return problems


def version_consistency() -> list[str]:
    version_file = ROOT / "VERSION"
    changelog = ROOT / "CHANGELOG.md"
    if not version_file.exists():
        return ["VERSION file is missing"]
    version = version_file.read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        return [f"VERSION '{version}' is not semver"]
    if changelog.exists():
        text = changelog.read_text(encoding="utf-8")
        if f"## [{version}]" not in text:
            return [f"CHANGELOG.md has no '## [{version}]' section"]
    return []


def leaked_credentials() -> list[str]:
    patterns = {
        "GitHub token": re.compile(r"gh[pousr]_[A-Za-z0-9]{36}"),
        "GitHub fine-grained PAT": re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
        "AWS access key": re.compile(r"AKIA[0-9A-Z]{16}"),
        "private key block": re.compile(r"-----BEGIN (?:RSA |EC )?PRIVATE KEY-----"),
        "OpenAI-style key": re.compile(r"sk-[A-Za-z0-9]{32,}"),
    }
    problems: list[str] = []
    for path in ROOT.glob("**/*"):
        if not path.is_file() or path.suffix not in TEXT_SUFFIXES:
            continue
        if ".zwork" in path.parts or ".git" in path.parts:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for label, pattern in patterns.items():
            if pattern.search(text):
                problems.append(f"{path.relative_to(ROOT)}: possible {label}")
    return problems


# ----------------------------------------------------------------------------- main


def main() -> int:
    print(f"local CI · {ROOT.name}\n")

    check("swift structure (16-token heuristic)", swift_structure())
    check("Info.plist", info_plist())
    check("YAML", yaml_files())
    check("power model invariants", model_invariants())
    check("markdown links", markdown_links())
    check("infographic assets", svg_assets())
    check("version consistency", version_consistency())
    check("credential scan", leaked_credentials())

    print()
    for warning in WARNINGS:
        print(f"  warning: {warning}")

    if FAILURES:
        print(f"\nFAILED — {len(FAILURES)} problem(s)")
        return 1

    print("All local checks passed.")
    print("Not covered here: Swift compilation and the 45 unit tests — those need macOS.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
