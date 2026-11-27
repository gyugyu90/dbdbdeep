#!/bin/sh
set -eu
TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$TASK_ROOT"
command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required." >&2; exit 1; }
command -v gitleaks >/dev/null 2>&1 || { echo "Install Gitleaks first: brew install gitleaks" >&2; exit 1; }
TASK_HOOKS="$(git config --get core.hooksPath || true)"
if [ -n "$TASK_HOOKS" ] && [ "$TASK_HOOKS" != ".githooks" ]; then
    echo "An existing core.hooksPath is configured. Keep it and integrate scripts/check-secrets.py into that hook." >&2
    exit 1
fi
TASK_EXISTING="$(git rev-parse --git-path hooks/pre-commit)"
if [ -z "$TASK_HOOKS" ] && [ -x "$TASK_EXISTING" ]; then
    echo "An existing pre-commit hook is installed. Integrate scripts/check-secrets.py into it before changing hooksPath." >&2
    exit 1
fi
git config --local core.hooksPath .githooks
echo "Enabled repository pre-commit secret checks."
