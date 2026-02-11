#!/usr/bin/env bash
set -euo pipefail

# queue-doctor.sh
# Diagnose (and optionally auto-fix) common causes of stuck YAML tasks in the file-based queue.
#
# Safe auto-fixes (when run with --fix):
# - remove stale watcher locks (pid not running)
# - move invalid host-run queue tasks to failed/ with waiting_for_human + a crisp question
# - requeue tasks stranded in doing/ with state=ready when the owning role lock is stale

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BASE="$REPO_ROOT/.agent-queue"
LOCKS_DIR="$BASE/logs/.locks"
FIX=false

if [[ "${1:-}" == "--fix" ]]; then
  FIX=true
fi

mkdir -p "$LOCKS_DIR"

now_epoch() { date +%s; }
mtime_epoch() { stat -c %Y "$1" 2>/dev/null || echo 0; }
age_s() { local f="$1"; echo $(( $(now_epoch) - $(mtime_epoch "$f") )); }

print_header() { echo; echo "=== $* ==="; }

list_tasks_with_age() {
  local label="$1" dir="$2"
  print_header "$label"
  if [[ ! -d "$dir" ]]; then
    echo "(missing dir) $dir"
    return 0
  fi
  shopt -s nullglob
  local files=("$dir"/*.yaml "$dir"/*.yml)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "(empty)"
    return 0
  fi
  for f in "${files[@]}"; do
    printf '%7ss  %s\n' "$(age_s "$f")" "$f"
  done | sort -nr
}

pid_running() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

fix_stale_lock_dir() {
  local lock_dir="$1"
  [[ -d "$lock_dir" ]] || return 0
  local pid=""
  pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then
    echo "stale lock (no pid): $lock_dir"
    if $FIX; then
      rm -f "$lock_dir/pid" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
      echo "  removed"
    fi
    return 0
  fi
  if ! pid_running "$pid"; then
    echo "stale lock (pid $pid not running): $lock_dir"
    if $FIX; then
      rm -f "$lock_dir/pid" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
      echo "  removed"
    fi
  fi
}

# Validate host-run queue task; if invalid, move to failed/ with waiting_for_human.
fail_invalid_host_task() {
  local task="$1"

  local reason
  reason="$(python3 - <<'PY' "$task" "$REPO_ROOT"
import sys, yaml
from pathlib import Path
p=Path(sys.argv[1])
repo_root=Path(sys.argv[2])
try:
  d=yaml.safe_load(p.read_text('utf-8')) or {}
except Exception:
  print('bad_yaml')
  raise SystemExit
state=str(d.get('state','') or '').strip()
role=str(d.get('role','') or '').strip()
cmds=d.get('host_commands')
if state!='needs_host_run':
  print('bad_state')
  raise SystemExit
if not role:
  print('missing_role')
  raise SystemExit
if not isinstance(cmds, list) or not cmds:
  print('bad_host_commands')
  raise SystemExit
# allowlist check
import subprocess
r=subprocess.run([sys.executable, str(repo_root/'scripts'/'host-command-allowlist.py'), '--file', str(p)], capture_output=True, text=True)
if r.returncode!=0:
  print('not_allowlisted')
  raise SystemExit
print('ok')
PY
)"

  if [[ "$reason" == "ok" ]]; then
    return 0
  fi

  echo "invalid host-run task: $task ($reason)"
  if ! $FIX; then
    echo "  (run with --fix to move it to failed/ with waiting_for_human)"
    return 0
  fi

  local question
  question="Host-run task is not runnable by the watcher (${reason}). Expected: state: needs_host_run and host_commands list containing allowlisted commands (see scripts/host-command-allowlist.py). Please fix and requeue."

  python3 "$REPO_ROOT/scripts/task-update.py" \
    --file "$task" \
    --set state=waiting_for_human \
    --set error=invalid_host_commands \
    --append "questions=$question" \
    --clear host_commands >/dev/null 2>&1 || true

  mkdir -p "$BASE/failed" 2>/dev/null || true
  mv "$task" "$BASE/failed/$(basename "$task")" 2>/dev/null || true
  echo "  moved to failed/: $BASE/failed/$(basename "$task")"
}

requeue_stranded_doing_ready() {
  local task="$1"
  local state
  state="$(python3 - <<'PY' "$task"
import sys, yaml
from pathlib import Path
p=Path(sys.argv[1])
try:
  d=yaml.safe_load(p.read_text('utf-8')) or {}
except Exception:
  print('')
  raise SystemExit
print(str(d.get('state','') or '').strip())
PY
)"
  [[ "$state" == "ready" ]] || return 0

  local role
  role="$(python3 - <<'PY' "$task"
import sys, yaml
from pathlib import Path
p=Path(sys.argv[1])
try:
  d=yaml.safe_load(p.read_text('utf-8')) or {}
except Exception:
  print('')
  raise SystemExit
print(str(d.get('role','') or '').strip())
PY
)"
  [[ -n "$role" ]] || return 0

  local lock_dir="$LOCKS_DIR/.agent-watch-${role}.lock"
  local pid=""
  pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && pid_running "$pid"; then
    return 0
  fi

  echo "stranded doing/ task with state=ready and no live ${role} watcher lock: $task"
  if ! $FIX; then
    echo "  (run with --fix to requeue to inbox/${role})"
    return 0
  fi

  mkdir -p "$BASE/inbox/$role" 2>/dev/null || true
  local base
  base="$(basename "$task")"
  base="${base#${role}-}"
  mv "$task" "$BASE/inbox/$role/$base"
  echo "  requeued to $BASE/inbox/$role/$base"
}

print_header "queue-doctor"
echo "repo_root=$REPO_ROOT"
echo "fix_mode=$FIX"

auto_roles="${AGENT_ROLES:-}" 

print_header "watcher locks (stale check)"
# Try to clean any lock dirs we can see.
for d in "$LOCKS_DIR"/*.lock; do
  [[ -d "$d" ]] || continue
  fix_stale_lock_dir "$d"
done

list_tasks_with_age "inbox" "$BASE/inbox"
list_tasks_with_age "doing" "$BASE/doing"
list_tasks_with_age "host-run" "$BASE/host-run"
list_tasks_with_age "failed" "$BASE/failed"

print_header "host-run queue validation"
shopt -s nullglob
for t in "$BASE/host-run"/*/*.y*ml; do
  [[ -e "$t" ]] || continue
  fail_invalid_host_task "$t"
done

print_header "stranded doing/ tasks"
for t in "$BASE/doing"/*.y*ml; do
  [[ -e "$t" ]] || continue
  requeue_stranded_doing_ready "$t"
done

echo
if $FIX; then
  echo "done (fixes applied where safe)"
else
  echo "done (diagnose only). Re-run with --fix to apply safe auto-fixes."
fi
