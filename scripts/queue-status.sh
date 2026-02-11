#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BASE="$REPO_ROOT/.agent-queue"

now=$(date +%s)

print_section() {
  local name="$1"; shift
  echo "== $name =="
  "$@" || true
  echo
}

age_line() {
  local f="$1"
  local m
  m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
  local age=$((now-m))
  printf '%7ss  %s\n' "$age" "$f"
}

print_section "doing (age)" bash -lc '
  shopt -s nullglob
  for f in '"$BASE"'/doing/*.y*ml; do
    '"$(declare -f age_line)"'
    age_line "$f"
  done | sort -nr
'

print_section "inbox" bash -lc '
  find '"$BASE"'/inbox -maxdepth 2 -type f -name "*.y*ml" -print | sort
'

print_section "host-run queue" bash -lc '
  find '"$BASE"'/host-run -maxdepth 2 -type f -name "*.y*ml" -print | sort
'

print_section "failed" bash -lc '
  find '"$BASE"'/failed -maxdepth 1 -type f -name "*.y*ml" -print | sort
'

print_section "done (latest 10)" bash -lc '
  ls -lt '"$BASE"'/done 2>/dev/null | head -n 12
'
