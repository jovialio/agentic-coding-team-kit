#!/usr/bin/env python3
"""Validate an agent task YAML file.

Exit codes:
- 0: valid
- 2: invalid usage
- 3: invalid YAML / schema

This validator is intentionally strict.

Configuration:
- Allowed roles come from env var `AGENT_ROLES` (comma-separated). Default: a,b
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import yaml


def fail(msg: str) -> int:
    print(msg, file=sys.stderr)
    return 3


def allowed_roles() -> set[str]:
    raw = os.getenv("AGENT_ROLES", "a,b")
    roles = {r.strip() for r in raw.split(",") if r.strip()}
    return roles or {"a", "b"}


ALLOWED_STATES = {
    "ready",
    "needs_host_run",
    "waiting_for_human",
    "blocked",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    args = ap.parse_args()

    p = Path(args.file)
    if not p.exists():
        return fail(f"Task not found: {p}")

    try:
        data = yaml.safe_load(p.read_text("utf-8")) or {}
    except Exception as e:
        return fail(f"Invalid YAML: {p}: {e}")

    if not isinstance(data, dict):
        return fail("Task YAML must be a mapping")

    for k in ("id", "role", "title", "state"):
        if k not in data or data.get(k) in (None, ""):
            return fail(f"Missing required field: {k}")

    role = str(data.get("role")).strip()
    if role not in allowed_roles():
        return fail(f"Invalid role: {role} (expected one of {sorted(allowed_roles())})")

    state = str(data.get("state")).strip()
    if state not in ALLOWED_STATES:
        return fail(f"Invalid state: {state} (expected one of {sorted(ALLOWED_STATES)})")

    for k in ("questions", "answers", "acceptance"):
        v = data.get(k)
        if v is None:
            continue
        if not isinstance(v, list):
            return fail(f"Field {k} must be a list")

    host_cmds = data.get("host_commands")
    if host_cmds is not None:
        if isinstance(host_cmds, str) and host_cmds.strip() == "":
            host_cmds = []
            data["host_commands"] = []
        if not isinstance(host_cmds, list):
            return fail("host_commands must be a list of strings")
        if any(not isinstance(x, str) for x in host_cmds):
            return fail("host_commands must be a list of strings")

    if state == "needs_host_run" and not host_cmds:
        return fail("state=needs_host_run requires non-empty host_commands")

    if state != "needs_host_run" and host_cmds:
        return fail("host_commands present but state is not needs_host_run")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
