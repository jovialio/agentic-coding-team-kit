#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUN_DIR="$REPO_ROOT/.agent-queue/run"
LOG_DIR="${WATCHER_LOG_DIR:-$REPO_ROOT/.agent-queue/logs}"

mkdir -p "$RUN_DIR" "$LOG_DIR"

# Default roles; override with AGENT_ROLES=a,b,c
ROLE_LIST="${AGENT_ROLES:-a,b}"

# Roles are a CSV. Default a,b; override with AGENT_ROLES.
IFS=',' read -r -a roles <<<"$ROLE_LIST"
# Watcher names are derived from roles.
watcher_names=()
for r in "${roles[@]}"; do
  r="${r// /}"
  [[ -n "$r" ]] || continue
  watcher_names+=("agent-$r")
done
watcher_names+=("host-run")

pid_file() { echo "$RUN_DIR/$1.pid"; }
log_file() { echo "$LOG_DIR/$1.log"; }

is_running() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

pgid_of() {
  local pid="$1"
  ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true
}

kill_group() {
  local sig="$1" pid="$2"
  local pgid
  pgid="$(pgid_of "$pid")"
  if [[ -n "$pgid" ]]; then
    kill "$sig" -- "-$pgid" 2>/dev/null || true
  fi
  kill "$sig" "$pid" 2>/dev/null || true
}

start_one() {
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

  echo "[start] $name"
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid bash -lc "cd '$cwd' && exec $cmd" >>"$lf" 2>&1 &
  else
    nohup bash -lc "cd '$cwd' && exec $cmd" >>"$lf" 2>&1 &
  fi

  pid=$!
  echo "$pid" >"$pf"
  sleep 0.3

  if is_running "$pid"; then
    echo "[ok] $name started (pid $pid, log: $lf)"
  else
    echo "[err] $name failed to start (check $lf)"
    return 1
  fi
}

stop_one() {
  local name="$1" pf pid
  pf="$(pid_file "$name")"
  [[ -f "$pf" ]] || { echo "[ok] $name not running"; return; }

  pid="$(cat "$pf" 2>/dev/null || true)"
  if is_running "$pid"; then
    kill_group -INT "$pid"

    for _ in {1..10}; do
      sleep 0.3
      ! is_running "$pid" && break
    done

    if is_running "$pid"; then
      kill_group -TERM "$pid"
      sleep 0.5
    fi

    if is_running "$pid"; then
      kill_group -KILL "$pid"
    fi

    echo "[stop] $name (pid $pid)"
  else
    echo "[ok] $name already stopped"
  fi
  rm -f "$pf"
}

print_lock_status() {
  local lock_dir="$1"
  if [[ -d "$lock_dir" ]]; then
    lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "$(basename "$lock_dir"): held (pid $lock_pid)"
    else
      echo "$(basename "$lock_dir"): stale (pid ${lock_pid:-?})"
    fi
  else
    echo "$(basename "$lock_dir"): not held"
  fi
}

status_one() {
  local name="$1" tail_lines="${2:-0}"
  local pf lf pid pgid
  pf="$(pid_file "$name")"
  lf="$(log_file "$name")"

  if [[ -f "$pf" ]]; then
    pid="$(cat "$pf" 2>/dev/null || true)"
    if is_running "$pid"; then
      pgid="$(pgid_of "$pid")"
      if [[ -n "$pgid" ]]; then
        echo "$name: running (pid $pid, pgid $pgid)"
      else
        echo "$name: running (pid $pid)"
      fi
      echo "  log: $lf"
      if [[ "$tail_lines" -gt 0 ]] && [[ -f "$lf" ]]; then
        echo "  tail ($tail_lines lines):"
        tail -n "$tail_lines" "$lf" 2>/dev/null | sed 's/^/    /' || true
      fi
      return
    fi
    echo "$name: stopped (stale pid file: $pf => $pid)"
    echo "  log: $lf"
    return
  fi

  echo "$name: stopped"
  echo "  log: $lf"
}

cmd="${1:-start}"
shift || true

case "$cmd" in
  start)
    use_worktrees="${USE_WORKTREES:-false}"
    if [[ "${1:-}" == "--worktrees" ]]; then
      use_worktrees="true"
      shift
    fi

    # Propagate role list for python validator.
    export AGENT_ROLES="$ROLE_LIST"

    repo_name="$(basename "$REPO_ROOT")"
    repo_parent="$(cd "$REPO_ROOT/.." && pwd)"

    # (Optional) ensure worktrees exist if requested.
    if [[ "$use_worktrees" == "true" ]]; then
      if [[ -x "$REPO_ROOT/scripts/worktree-setup.sh" ]]; then
        "$REPO_ROOT/scripts/worktree-setup.sh" "$ROLE_LIST" >/dev/null || true
      else
        echo "[err] worktree-setup.sh not found/executable; cannot use --worktrees" >&2
        exit 1
      fi
    fi

    # Start role watchers
    for r in "${roles[@]}"; do
      r="${r// /}"
      [[ -n "$r" ]] || continue

      cwd="$REPO_ROOT"
      if [[ "$use_worktrees" == "true" ]]; then
        cwd="$repo_parent/${repo_name}-${r}"
      fi

      start_one "agent-$r" "./scripts/agent-watch.sh $r" "$cwd"
    done

    # Start host-run watcher from main repo root
    start_one "host-run" "./scripts/host-run-watch.sh" "$REPO_ROOT"
    ;;

  stop)
    for name in "${watcher_names[@]}"; do
      stop_one "$name"
    done
    ;;

  restart)
    "$0" stop
    "$0" start
    ;;

  status)
    tail_lines=0
    if [[ "${1:-}" == "--tail" ]]; then
      tail_lines="${2:-5}"
    elif [[ "${1:-}" =~ ^[0-9]+$ ]]; then
      tail_lines="$1"
    fi

    for name in "${watcher_names[@]}"; do
      status_one "$name" "$tail_lines"
    done

    echo
    echo "locks:"
    print_lock_status "$REPO_ROOT/.agent-queue/logs/.locks/.host-run.lock"
    ;;

  *)
    echo "Usage: $0 {start [--worktrees]|stop|restart|status [--tail N]}" >&2
    exit 2
    ;;
esac
