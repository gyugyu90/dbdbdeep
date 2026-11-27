#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def git(root, *arguments, data=None):
    return subprocess.run(
        ["git", *arguments], cwd=root, input=data, capture_output=True, check=True
    ).stdout


def check(root, all_files=False):
    arguments = ["ls-files", "-z"] if all_files else [
        "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"
    ]
    paths = [os.fsdecode(path) for path in git(root, *arguments).split(b"\0") if path]
    if not paths:
        print("Secret check: no staged files to scan.")
        return 0
    ignored = subprocess.run(
        ["git", "check-ignore", "--no-index", "-z", "--stdin"], cwd=root,
        input=b"\0".join(os.fsencode(path) for path in paths) + b"\0",
        capture_output=True,
    )
    if ignored.returncode not in (0, 1):
        raise RuntimeError("Could not check ignored file policy.")
    forbidden = [os.fsdecode(path) for path in ignored.stdout.split(b"\0") if path]
    if forbidden:
        print("Commit blocked: ignored local/private files are staged:", file=sys.stderr)
        for path in forbidden:
            print(f"  {path}", file=sys.stderr)
        print("Unstage these files and keep personal settings outside Git.", file=sys.stderr)
        return 1
    executable = shutil.which("gitleaks")
    if not executable:
        print("Secret check cannot run. Install Gitleaks: brew install gitleaks", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix="dbdbdeep-secret-check-") as directory:
        snapshot = Path(directory)
        for name in paths:
            path = Path(name)
            if path.is_absolute() or ".." in path.parts:
                raise RuntimeError("Invalid staged path.")
            target = snapshot / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(git(root, "show", ":" + name))
        result = subprocess.run(
            [executable, "dir", str(snapshot), "--config", str(root / ".gitleaks.toml"),
             "--redact=100", "--no-banner", "--no-color", "--log-level=error",
             "--ignore-gitleaks-allow", "--max-archive-depth=2",
             "--report-format=json", "--report-path=-"],
            cwd=root, capture_output=True, text=True,
        )
        try:
            findings = json.loads(result.stdout)
            if not isinstance(findings, list):
                raise ValueError("Invalid report.")
        except (ValueError, json.JSONDecodeError):
            print("Secret check failed to produce a valid report; commit blocked.", file=sys.stderr)
            return 2
        if findings:
            print("Commit blocked: possible secrets in staged content (values hidden):", file=sys.stderr)
            for finding in findings:
                name = finding.get("File", "unknown")
                if Path(name).is_absolute():
                    try:
                        name = str(Path(name).relative_to(snapshot))
                    except ValueError:
                        name = "unknown"
                print(f"  {name}:{finding.get('StartLine', '?')} [{finding.get('RuleID', 'unknown')}]", file=sys.stderr)
            return 1
        if result.returncode:
            print("Gitleaks could not complete the check; commit blocked.", file=sys.stderr)
            return 2
    print(f"Secret check passed: {len(paths)} staged files.")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Scan Git index contents without exposing secret values.")
    parser.add_argument("--all", action="store_true", help="Check all tracked index files, not only staged changes.")
    arguments = parser.parse_args()
    try:
        return check(Path(__file__).resolve().parent.parent, arguments.all)
    except (OSError, RuntimeError, subprocess.CalledProcessError):
        print("Secret check could not read the staged snapshot; commit blocked.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
