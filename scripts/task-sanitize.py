#!/usr/bin/env python3
"""Sanitize task YAML to avoid watcher/validator churn.

Usage:
  python3 scripts/task-sanitize.py --file .agent-queue/inbox/a/A-001.yaml

Normalizes common type mistakes:
- host_commands: '' -> []
- list fields: null -> []
- attempts_* strings -> ints when safe
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml


def sanitize(data: dict) -> tuple[dict, bool]:
    changed = False

    hc = data.get("host_commands")
    if isinstance(hc, str) and hc.strip() == "":
        data["host_commands"] = []
        changed = True

    for k in ("questions", "answers", "acceptance"):
        if k in data and data[k] is None:
            data[k] = []
            changed = True

    for k in ("attempts_agent", "attempts_host"):
        v = data.get(k)
        if isinstance(v, str) and v.strip().isdigit():
            data[k] = int(v.strip())
            changed = True

    return data, changed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    args = ap.parse_args()

    p = Path(args.file)
    if not p.exists():
        print(f"Task not found: {p}", file=sys.stderr)
        return 2

    try:
        data = yaml.safe_load(p.read_text("utf-8")) or {}
    except Exception as e:
        print(f"Invalid YAML: {p}: {e}", file=sys.stderr)
        return 3

    if not isinstance(data, dict):
        print("Task YAML must be a mapping", file=sys.stderr)
        return 3

    data, changed = sanitize(data)
    if changed:
        p.write_text(
            yaml.safe_dump(
                data,
                sort_keys=False,
                allow_unicode=True,
                default_flow_style=False,
                width=1000,
            ),
            "utf-8",
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
