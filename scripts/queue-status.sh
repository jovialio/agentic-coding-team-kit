#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BASE="$REPO_ROOT/.agent-queue"

# Note: age_line computes now() internally so it works inside the bash -lc subshell blocks below.

print_section() {
  local name="$1"; shift
  echo "== $name =="
  "$@" || true
  echo
}

age_line() {
  local f="$1"
  local now
  now=$(date +%s)
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

print_section "inbox (age)" bash -lc '
  shopt -s nullglob
  for f in '"$BASE"'/inbox/*/*.y*ml; do
    '"$(declare -f age_line)"'
    age_line "$f"
  done | sort -nr
'

print_section "host-run queue (age)" bash -lc '
  shopt -s nullglob
  for f in '"$BASE"'/host-run/*/*.y*ml; do
    '"$(declare -f age_line)"'
    age_line "$f"
  done | sort -nr
'

print_section "failed" bash -lc '
  find '"$BASE"'/failed -maxdepth 1 -type f -name "*.y*ml" -print 2>/dev/null | sort
'

print_section "done (latest 10)" bash -lc '
  ls -lt '"$BASE"'/done 2>/dev/null | head -n 12
'
