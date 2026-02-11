#!/usr/bin/env bash
set -euo pipefail

# Generic host-run watcher.
#
# Watches .agent-queue/host-run/<role>/ for tasks with:
# - state: needs_host_run
# - host_commands: [ ... ]
#
# Runs allowlisted commands, writes a short summary to answers, clears host_commands,
# sets state: ready, and requeues back to inbox/<role>/.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BASE_DIR="$REPO_ROOT/.agent-queue"
INBOX_DIR="$BASE_DIR/inbox"
HOST_RUN_DIR="$BASE_DIR/host-run"
FAILED_DIR="$BASE_DIR/failed"
# Locks must be shared across worktrees because the runtime queue is shared.
LOCK_DIR="$BASE_DIR/logs/.locks/.host-run.lock"
LOG_DIR="${WATCHER_LOG_DIR:-$BASE_DIR/logs}"
LOG_FILE="$LOG_DIR/host-run-watch.log"

mkdir -p "$INBOX_DIR" "$HOST_RUN_DIR" "$FAILED_DIR" "$LOG_DIR" "$BASE_DIR/logs/.locks"

# Ensure PyYAML is available.
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "ERROR: PyYAML is not installed for python3. Install it (e.g. apt-get install python3-yaml or pip install pyyaml)" >&2
  exit 1
fi

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG_FILE" >&2
}

acquire_lock() {
  while true; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "$$" >"$LOCK_DIR/pid" 2>/dev/null || true
      trap 'rm -f "$LOCK_DIR/pid" 2>/dev/null || true; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
      return 0
    fi

    if [[ -f "$LOCK_DIR/pid" ]]; then
      lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
      if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
        log "Stale host-run lock detected (pid $lock_pid not running). Removing lock."
        rm -f "$LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
        continue
      fi
    else
      log "host-run lock exists without pid file. Removing lock."
      rmdir "$LOCK_DIR" 2>/dev/null || true
      continue
    fi

    sleep 2
  done
}

should_handle() {
  local task="$1"
  python3 - <<'PY' "$task"
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8', errors='replace')
try:
  data = yaml.safe_load(text) or {}
except Exception:
  sys.exit(1)
role = str(data.get('role','')).strip()
state = str(data.get('state','')).strip()
cmds = data.get('host_commands')
if role and state == 'needs_host_run' and isinstance(cmds, list) and len(cmds) > 0:
  print(role)
  sys.exit(0)
sys.exit(1)
PY
}

extract_cmds() {
  local task="$1"
  python3 "$REPO_ROOT/scripts/host-command-allowlist.py" --file "$task"
}

move_to_failed_waiting() {
  local task="$1" reason="$2"
  local question
  question="Host-run task is not runnable: ${reason}. Expected: state: needs_host_run and host_commands: [ ... ] containing allowlisted commands (see scripts/host-command-allowlist.py). Please fix and requeue."
  "$REPO_ROOT/scripts/task-update.py" \
    --file "$task" \
    --set state=waiting_for_human \
    --set error=invalid_host_commands \
    --append "questions=$question" \
    --clear host_commands >/dev/null 2>&1 || true
  dest="$FAILED_DIR/$(basename "$task")"
  if [[ -e "$dest" ]]; then
    dest="$FAILED_DIR/$(basename "$task").$(date -u +'%Y%m%dT%H%M%SZ')"
  fi
  mv "$task" "$dest" 2>/dev/null || true
  log "Invalid task; moved to failed: $dest"
}

requeue_dest_name() {
  local src="$1" role="$2" base
  base="$(basename "$src")"
  # Normalize: doing/<role>-XYZ.yaml or host-run/<role>-XYZ.yaml -> inbox/<role>/XYZ.yaml
  if [[ "$base" == "$role-"* ]]; then
    base="${base#${role}-}"
  fi
  printf '%s' "$base"
}

run_cmd() {
  local cmd="$1"

  # Belt & suspenders: if a repo uses a Playwright wrapper that supports native runs
  # (e.g. when E2E_MANUAL_SERVER=1), avoid accidentally forcing Docker mode.
  if [[ "$cmd" == *"E2E_MANUAL_SERVER=1"* ]] && [[ "$cmd" != *"PW_DOCKER="* ]]; then
    cmd="PW_DOCKER=0 $cmd"
  fi

  log "Running: $cmd"
  (cd "$REPO_ROOT" && bash -lc "$cmd")
}

update_task_and_requeue() {
  local task_path="$1" role="$2" cmd="$3" exit_code="$4" out_path="$5"

  local now_utc
  now_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  "$REPO_ROOT/scripts/task-update.py" \
    --file "$task_path" \
    --set last_host_run_at="$now_utc" \
    --set last_host_exit="$exit_code" \
    --set last_host_log="$out_path" >/dev/null || true

  # attempts_host++
  python3 - <<'PY' "$task_path" "$REPO_ROOT" >/dev/null || true
import pathlib, yaml, sys
p=pathlib.Path(sys.argv[1])
repo_root=pathlib.Path(sys.argv[2])
try:
  data=yaml.safe_load(p.read_text('utf-8')) or {}
except Exception:
  sys.exit(0)
val=data.get('attempts_host',0)
try:
  val=int(val)
except Exception:
  val=0
val+=1
from subprocess import run
run(['python3', str(repo_root/'scripts'/'task-update.py'), '--file', str(p), '--set', f'attempts_host={val}'], check=False)
PY

  status_word="PASSED"; [[ "$exit_code" -ne 0 ]] && status_word="FAILED"

  answer=$(python3 - <<'PY' "$cmd" "$status_word" "$exit_code" "$out_path"
import sys
cmd, status, code, out_path = sys.argv[1:]
print(f"Host-run: {cmd} -> {status} (exit {code}). Full output: {out_path}")
PY
)

  if [[ "$exit_code" -eq 0 ]]; then
    "$REPO_ROOT/scripts/task-update.py" \
      --file "$task_path" \
      --set state=ready \
      --set error="" \
      --append "answers=$answer" \
      --clear host_commands >/dev/null || true
  else
    "$REPO_ROOT/scripts/task-update.py" \
      --file "$task_path" \
      --set state=ready \
      --set error=host_run_failed \
      --append "answers=$answer" \
      --clear host_commands >/dev/null || true
  fi

  mkdir -p "$INBOX_DIR/$role"
  dest="$INBOX_DIR/$role/$(requeue_dest_name "$task_path" "$role")"
  if [[ -e "$dest" ]]; then
    ts="$(date -u +'%Y%m%dT%H%M%SZ')"
    dest="$INBOX_DIR/$role/${ts}-$(requeue_dest_name "$task_path" "$role")"
  fi

  mv "$task_path" "$dest"
  log "Requeued: $dest"
}

main() {
  acquire_lock
  log "host-run watcher started"

  while true; do
    handled_any=0

    mapfile -t tasks < <(find "$HOST_RUN_DIR" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | LC_ALL=C sort -V)
    for task in "${tasks[@]}"; do
      role=""
      if ! role=$(should_handle "$task" 2>/dev/null); then
        # Anything sitting in the explicit host-run queue should be actionable.
        move_to_failed_waiting "$task" "bad state/role/host_commands (expected state: needs_host_run + host_commands list)"
        handled_any=1
        break
      fi

      if ! cmds=$(extract_cmds "$task" 2>/dev/null); then
        handled_any=1
        move_to_failed_waiting "$task" "host_commands missing/empty or contains non-allowlisted commands"
        break
      fi

      handled_any=1
      ts="$(date -u +'%Y%m%dT%H%M%SZ')"
      out_file="$LOG_DIR/host-run-${ts}-$(basename "$task").log"

      set +e
      first_cmd=$(printf '%s\n' "$cmds" | head -n 1)
      run_cmd "$first_cmd" >"$out_file" 2>&1
      code=$?
      set -e

      update_task_and_requeue "$task" "$role" "$first_cmd" "$code" "$out_file"
      break
    done

    if [[ "$handled_any" -eq 0 ]]; then
      sleep 3
    fi
  done
}

main "$@"
