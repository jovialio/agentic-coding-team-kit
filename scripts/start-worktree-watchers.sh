#!/usr/bin/env bash
set -euo pipefail

# start-worktree-watchers.sh
#
# Start role watchers from per-role worktrees created by worktree-setup.sh.
# Keeps host-run watcher running from the main repo root.
#
# Usage:
#   ./scripts/start-worktree-watchers.sh start a,b
#   ./scripts/start-worktree-watchers.sh status
#   ./scripts/start-worktree-watchers.sh stop

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REPO_NAME="$(basename "$REPO_ROOT")"
RUN_DIR="$REPO_ROOT/.agent-queue/run"
LOG_DIR="${WATCHER_LOG_DIR:-$REPO_ROOT/.agent-queue/logs}"

mkdir -p "$RUN_DIR" "$LOG_DIR"

ROLE_LIST="${2:-${AGENT_ROLES:-a,b}}"

pid_file() { echo "$RUN_DIR/$1.pid"; }
log_file() { echo "$LOG_DIR/$1.log"; }

is_running() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

start_cmd() {
  local name="$1" cmd="$2" cwd="$3"
  local pf lf pid
  pf="$(pid_file "$name")"
  lf="$(log_file "$name")"

  if [[ -f "$pf" ]]; then
    pid="$(cat "$pf" 2>/dev/null || true)"
    if is_running "$pid"; then
      echo "[ok] $name already running (pid $pid)"
      return
    fi
  fi

  echo "[start] $name (cwd: $cwd)"
  nohup bash -lc "cd '$cwd' && exec $cmd" >>"$lf" 2>&1 &
  pid=$!
  echo "$pid" >"$pf"
}

stop_one() {
  local name="$1" pf pid
  pf="$(pid_file "$name")"
  [[ -f "$pf" ]] || { echo "[ok] $name not running"; return; }
  pid="$(cat "$pf" 2>/dev/null || true)"
  if is_running "$pid"; then
    kill -INT "$pid" 2>/dev/null || true
    sleep 0.5
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.5
    kill -KILL "$pid" 2>/dev/null || true
    echo "[stop] $name (pid $pid)"
  fi
  rm -f "$pf"
}

status_one() {
  local name="$1" pf pid
  pf="$(pid_file "$name")"
  if [[ -f "$pf" ]]; then
    pid="$(cat "$pf" 2>/dev/null || true)"
    if is_running "$pid"; then
      echo "$name: running (pid $pid)"
      return
    fi
    echo "$name: stopped (stale pid file)"
    return
  fi
  echo "$name: stopped"
}

cmd="${1:-start}"
case "$cmd" in
  start)
    # Ensure worktrees exist
    "$REPO_ROOT/scripts/worktree-setup.sh" "$ROLE_LIST" >/dev/null || true

    IFS=',' read -r -a roles <<<"$ROLE_LIST"
    for r in "${roles[@]}"; do
      r="${r// /}"
      [[ -n "$r" ]] || continue
      wt_path="$(cd "$REPO_ROOT/.." && pwd)/${REPO_NAME}-${r}"
      start_cmd "agent-$r" "./scripts/agent-watch.sh $r" "$wt_path"
    done

    # host-run watcher from main repo root
    start_cmd "host-run" "./scripts/host-run-watch.sh" "$REPO_ROOT"
    ;;
  stop)
    IFS=',' read -r -a roles <<<"${AGENT_ROLES:-a,b}"
    for r in "${roles[@]}"; do
      r="${r// /}"
      [[ -n "$r" ]] || continue
      stop_one "agent-$r"
    done
    stop_one "host-run"
    ;;
  status)
    IFS=',' read -r -a roles <<<"${AGENT_ROLES:-a,b}"
    for r in "${roles[@]}"; do
      r="${r// /}"
      [[ -n "$r" ]] || continue
      status_one "agent-$r"
    done
    status_one "host-run"
    ;;
  *)
    echo "Usage: $0 {start|stop|status} [roles_csv]" >&2
    exit 2
    ;;
esac
