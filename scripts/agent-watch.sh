#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:-}"
if [[ -z "$ROLE" ]]; then
  echo "Usage: $0 <role>" >&2
  exit 1
fi

# Ensure PyYAML is available (required by task-validate/task-update).
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "ERROR: PyYAML is not installed for python3. Install it (e.g. apt-get install python3-yaml or pip install pyyaml)" >&2
  exit 1
fi

BASE_DIR=".agent-queue"
INBOX_DIR="$BASE_DIR/inbox/$ROLE"
DOING_DIR="$BASE_DIR/doing"
DONE_DIR="$BASE_DIR/done"
FAILED_DIR="$BASE_DIR/failed"
HOST_RUN_DIR="$BASE_DIR/host-run/$ROLE"
PROMPT_FILE="prompts/codex-$ROLE.txt"

mkdir -p "$INBOX_DIR" "$DOING_DIR" "$DONE_DIR" "$FAILED_DIR" "$HOST_RUN_DIR"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Missing prompt file: $PROMPT_FILE" >&2
  exit 1
fi

CURRENT_TASK=""

safe_move() {
  local src="$1" dest_dir="$2" base_name dest ts
  base_name="$(basename "$src")"
  dest="$dest_dir/$base_name"
  if [[ -e "$dest" ]]; then
    ts="$(date +%s)"
    dest="$dest_dir/${base_name%.*}-$ts.${base_name##*.}"
  fi
  mv "$src" "$dest"
}

append_interrupt_fields() {
  local task_path="$1"
  python3 scripts/task-update.py --file "$task_path" \
    --set interrupted=true \
    --set interrupted_reason=watcher_stop >/dev/null || true
}

handle_interrupt() {
  if [[ -n "$CURRENT_TASK" && -f "$CURRENT_TASK" ]]; then
    append_interrupt_fields "$CURRENT_TASK"
    safe_move "$CURRENT_TASK" "$FAILED_DIR"
  fi
  exit 130
}

trap handle_interrupt INT TERM HUP

auto_requeue_ready_from_doing() {
  local candidates=()
  mapfile -t candidates < <((ls -1 "$DOING_DIR/${ROLE}-"*.yaml "$DOING_DIR/${ROLE}-"*.yml 2>/dev/null || true) | LC_ALL=C sort -V)
  for task in "${candidates[@]}"; do
    [[ -f "$task" ]] || continue
    if grep -qE '^state:\s*ready\b' "$task"; then
      base="$(basename "$task")"
      dest_name="${base#${ROLE}-}"
      dest="$INBOX_DIR/$dest_name"
      if [[ -e "$dest" ]]; then
        ts="$(date +%s)"
        dest="$INBOX_DIR/${dest_name%.*}-$ts.${dest_name##*.}"
      fi
      mv "$task" "$dest"
      echo "Requeued resumed task: $dest"
      return 0
    fi
  done
  return 1
}

echo "Starting role watcher: $ROLE (inbox: $INBOX_DIR)"

while true; do
  auto_requeue_ready_from_doing || true

  TASK_FILE=""
  mapfile -t TASK_CANDIDATES < <((ls -1 "$INBOX_DIR"/*.yaml "$INBOX_DIR"/*.yml 2>/dev/null || true) | LC_ALL=C sort -V)
  if [[ ${#TASK_CANDIDATES[@]} -gt 0 ]]; then
    TASK_FILE="${TASK_CANDIDATES[0]}"
  fi

  if [[ -z "$TASK_FILE" ]]; then
    sleep 2
    continue
  fi

  # Validate early; invalid tasks go to failed.
  if ! python3 scripts/task-validate.py --file "$TASK_FILE" >/dev/null 2>&1; then
    python3 scripts/task-update.py --file "$TASK_FILE" --set error=invalid_task_yaml >/dev/null || true
    safe_move "$TASK_FILE" "$FAILED_DIR"
    sleep 1
    continue
  fi

  BASE_NAME="$(basename "$TASK_FILE")"
  DOING_PATH="$DOING_DIR/${ROLE}-${BASE_NAME}"
  mv "$TASK_FILE" "$DOING_PATH"
  CURRENT_TASK="$DOING_PATH"

  now_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  python3 scripts/task-update.py --file "$CURRENT_TASK" --set last_agent_run_at="$now_utc" >/dev/null || true

  PROMPT_TEXT="$(cat "$PROMPT_FILE")"

  if ! command -v codex >/dev/null 2>&1; then
    python3 scripts/task-update.py --file "$CURRENT_TASK" --set error=codex_not_found >/dev/null || true
    safe_move "$CURRENT_TASK" "$FAILED_DIR"
    CURRENT_TASK=""
    continue
  fi

  set +e
  codex exec \
    --sandbox workspace-write \
    --config approval_policy=never \
    "$PROMPT_TEXT"$'\n\n'"Task file: $CURRENT_TASK"
  STATUS=$?
  set -e

  python3 scripts/task-update.py --file "$CURRENT_TASK" --set last_agent_exit="$STATUS" >/dev/null || true

  if grep -qE '^state:\s*waiting_for_human\b' "$CURRENT_TASK"; then
    echo "Task waiting for human input (leaving in doing): $CURRENT_TASK"
    CURRENT_TASK=""
    continue
  fi

  if grep -qE '^state:\s*needs_host_run\b' "$CURRENT_TASK"; then
    echo "Task needs host-run (moving to host-run queue): $CURRENT_TASK"
    mkdir -p "$HOST_RUN_DIR"
    safe_move "$CURRENT_TASK" "$HOST_RUN_DIR"
    CURRENT_TASK=""
    continue
  fi

  if [[ $STATUS -eq 0 ]]; then
    safe_move "$CURRENT_TASK" "$DONE_DIR"
  else
    python3 scripts/task-update.py --file "$CURRENT_TASK" --set "error=codex_exit_${STATUS}" >/dev/null || true
    safe_move "$CURRENT_TASK" "$FAILED_DIR"
  fi

  CURRENT_TASK=""
done
