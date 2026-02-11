#!/usr/bin/env python3
"""Canonical YAML task updater (atomic write).

Why:
- Multiple automation flows update task YAML files (agents + watchers + host-runner).
- Raw text edits are brittle and can corrupt YAML.

This utility performs safe YAML round-trips:
- yaml.safe_load -> mutate -> yaml.safe_dump
- atomic write (tmp + rename)

Usage examples:
  scripts/task-update.py --file TASK.yaml --set state=ready --append answers="..."

Notes:
- Values passed to --set are treated as strings.
- Use --set-json for structured values (lists/dicts/bools/null).
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

import yaml


def parse_kv(s: str) -> tuple[str, str]:
    if "=" not in s:
        raise ValueError(f"Expected KEY=VALUE, got: {s}")
    k, v = s.split("=", 1)
    return k.strip(), v


def ensure_list(data: dict, key: str) -> list:
    v = data.get(key)
    if v is None:
        data[key] = []
        return data[key]
    if isinstance(v, list):
        return v
    data[key] = [v]
    return data[key]


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        delete=False,
        dir=str(path.parent),
        prefix=path.name + ".tmp.",
    ) as tf:
        tf.write(content)
        tmp = Path(tf.name)
    tmp.replace(path)


def sanitize_known_fields(data: dict) -> None:
    # host_commands: '' -> []
    hc = data.get("host_commands")
    if isinstance(hc, str) and hc.strip() == "":
        data["host_commands"] = []

    # list fields: null -> []
    for k in ("questions", "answers", "acceptance", "contract_paths"):
        if k in data and data[k] is None:
            data[k] = []


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--set", action="append", default=[])
    ap.add_argument("--set-json", action="append", default=[])
    ap.add_argument("--append", action="append", default=[])
    ap.add_argument("--clear", action="append", default=[])
    args = ap.parse_args()

    p = Path(args.file)
    if not p.exists():
        print(f"Task not found: {p}", file=sys.stderr)
        return 2

    try:
        data = yaml.safe_load(p.read_text("utf-8")) or {}
        if not isinstance(data, dict):
            raise TypeError("YAML root must be a mapping")
    except Exception as e:
        print(f"Failed to parse YAML: {p}: {e}", file=sys.stderr)
        return 3

    for k in args.clear:
        key = k.strip()
        if key:
            data[key] = ""

    for kv in args.set:
        k, v = parse_kv(kv)
        data[k] = v

    for kv in args.set_json:
        k, v = parse_kv(kv)
        data[k] = json.loads(v)

    for kv in args.append:
        k, v = parse_kv(kv)
        lst = ensure_list(data, k)
        lst.append(v)

    sanitize_known_fields(data)

    dumped = yaml.safe_dump(
        data,
        sort_keys=False,
        allow_unicode=True,
        default_flow_style=False,
        width=1000,
    )

    atomic_write(p, dumped)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
