#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUN_DIR="$REPO_ROOT/.agent-queue/run"
LOG_DIR="${WATCHER_LOG_DIR:-$REPO_ROOT/.agent-queue/logs}"

mkdir -p "$RUN_DIR" "$LOG_DIR"

# Default roles; override with AGENT_ROLES=a,b,c
ROLE_LIST="${AGENT_ROLES:-a,b}"

# Build watcher list dynamically based on ROLE_LIST.
watchers=()
IFS=',' read -r -a roles <<<"$ROLE_LIST"
for r in "${roles[@]}"; do
  r="${r// /}"
  [[ -n "$r" ]] || continue
  watchers+=("agent-$r|./scripts/agent-watch.sh $r")
done
watchers+=("host-run|./scripts/host-run-watch.sh")

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
  local name="$1" cmd="$2"
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
    nohup setsid bash -lc "cd '$REPO_ROOT' && exec $cmd" >>"$lf" 2>&1 &
  else
    nohup bash -lc "cd '$REPO_ROOT' && exec $cmd" >>"$lf" 2>&1 &
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
case "$cmd" in
  start)
    # Propagate role list for python validator.
    export AGENT_ROLES="$ROLE_LIST"

    for w in "${watchers[@]}"; do
      IFS='|' read -r name run_cmd <<<"$w"
      start_one "$name" "$run_cmd"
    done
    ;;
  stop)
    for w in "${watchers[@]}"; do
      IFS='|' read -r name _ <<<"$w"
      stop_one "$name"
    done
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  status)
    tail_lines=0
    if [[ "${2:-}" == "--tail" ]]; then
      tail_lines="${3:-5}"
    elif [[ "${2:-}" =~ ^[0-9]+$ ]]; then
      tail_lines="$2"
    fi

    for w in "${watchers[@]}"; do
      IFS='|' read -r name _ <<<"$w"
      status_one "$name" "$tail_lines"
    done

    echo
    echo "locks:"
    print_lock_status "$REPO_ROOT/.agent-queue/.host-run.lock"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status [--tail N]}" >&2
    exit 2
    ;;
esac
