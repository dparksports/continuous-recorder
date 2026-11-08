#!/usr/bin/env python3
"""Cut a release from this machine, gated on local CI.

Order matters and is deliberate: local CI runs *before* anything is tagged, so a
broken tree never gets a version number attached to it.

    python scripts/release.py --dry-run     # show what would happen
    python scripts/release.py               # actually tag, push, release

Requires: git, gh (authenticated), clean working tree, VERSION matching CHANGELOG.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(command: list[str], dry_run: bool, capture: bool = False) -> subprocess.CompletedProcess:
    printable = " ".join(command)
    print(f"  $ {printable}")
    if dry_run:
        return subprocess.CompletedProcess(command, 0, "", "")
    return subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        capture_output=capture,
        check=False,
    )


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"\nABORT: {message}")
        sys.exit(1)


def changelog_section(version: str) -> str:
    text = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    marker = f"## [{version}]"
    start = text.find(marker)
    require(start >= 0, f"CHANGELOG.md has no '{marker}' section")
    following = text.find("\n## ", start + len(marker))
    body = text[start: following if following > 0 else len(text)]
    return body.strip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Run local CI, then tag and publish a release")
    parser.add_argument("--dry-run", action="store_true", help="print commands without running them")
    parser.add_argument("--skip-ci", action="store_true", help="only for re-running a release step")
    args = parser.parse_args()

    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    tag = f"v{version}"
    print(f"Releasing {tag} from {ROOT}\n")

    # --- preconditions -------------------------------------------------------
    status = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT,
                            text=True, capture_output=True, check=False)
    require(status.returncode == 0, "not a git repository")
    require(status.stdout.strip() == "", "working tree is dirty — commit or stash first")

    existing = subprocess.run(["git", "tag", "--list", tag], cwd=ROOT,
                              text=True, capture_output=True, check=False)
    require(existing.stdout.strip() == "", f"tag {tag} already exists")

    branch = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=ROOT,
                            text=True, capture_output=True, check=False).stdout.strip()
    require(branch == "main", f"releases are cut from main, currently on '{branch}'")

    notes = changelog_section(version)
    print(f"Release notes: {len(notes.splitlines())} lines from CHANGELOG.md\n")

    # --- local CI ------------------------------------------------------------
    if args.skip_ci:
        print("Skipping local CI (--skip-ci)")
    else:
        print("Running local CI…")
        result = run([sys.executable, str(ROOT / "scripts" / "local_ci.py")], args.dry_run)
        if not args.dry_run:
            require(result.returncode == 0, "local CI failed — fix it before releasing")
        print()

    # --- tag, push, release --------------------------------------------------
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as handle:
        handle.write(notes)
        notes_path = Path(handle.name)

    try:
        tag_result = run(["git", "tag", "-a", tag, "-m", f"{tag}"], args.dry_run)
        if not args.dry_run:
            require(tag_result.returncode == 0, "could not create the tag")

        push_result = run(["git", "push", "origin", branch], args.dry_run)
        if not args.dry_run:
            require(push_result.returncode == 0, "could not push the branch")

        tag_push = run(["git", "push", "origin", tag], args.dry_run)
        if not args.dry_run:
            require(tag_push.returncode == 0, "could not push the tag")

        release_result = run(
            [
                "gh", "release", "create", tag,
                "--title", f"Continuous Recorder {tag}",
                "--notes-file", str(notes_path),
                "--attach", "assets/runtime-budget.png",
                "--attach", "assets/tamper-chain.png",
            ],
            args.dry_run,
        )
        if not args.dry_run:
            require(release_result.returncode == 0, "gh release create failed")
    finally:
        notes_path.unlink(missing_ok=True)

    if args.dry_run:
        print(f"\nDry run — nothing was tagged, pushed or published. {len(notes.splitlines())} lines of notes are ready for {tag}.")
    else:
        print(f"\nDone — {tag} published with notes from CHANGELOG.md and both infographics attached.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
