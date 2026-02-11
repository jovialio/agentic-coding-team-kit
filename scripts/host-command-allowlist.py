#!/usr/bin/env python3
"""Extract allowlisted host-run commands from a task YAML.

This template keeps the default allowlist intentionally narrow.
Update this file to match your team's preferred test commands.

Exit codes:
- 0: printed one or more allowlisted commands (one per line)
- 1: no allowlisted commands (or invalid YAML/shape)
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml


def normalize_cmd(raw: str) -> str:
    return raw.strip().strip("`").strip('"').strip("'").rstrip(" .")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    args = ap.parse_args()

    p = Path(args.file)
    try:
        data = yaml.safe_load(p.read_text(encoding="utf-8", errors="replace")) or {}
    except Exception:
        return 1

    if not isinstance(data, dict):
        return 1

    cmds = data.get("host_commands")
    if not isinstance(cmds, list) or not cmds:
        return 1

    # Default allowlist examples (edit to suit your repo):
    allow = re.compile(
        r"^(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*"  # optional env prefixes
        r"(?:"
        r"make\s+(?:test|lint|typecheck)\b"
        r"|pytest\b"
        r"|npm\s+test\b"
        r"|pnpm\s+test\b"
        r")"
    )

    out: list[str] = []
    for raw in cmds:
        if not isinstance(raw, str):
            continue
        cmd = normalize_cmd(raw)
        if allow.match(cmd):
            out.append(cmd)

    if not out:
        return 1

    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
