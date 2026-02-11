#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: task-new.sh <role> <ID> <TITLE> [created_by] [options]

Options:
  --notes "text"            Task guidance
  --notes-stdin             Read multi-line notes from stdin (Ctrl-D to finish)
  --acceptance "cmd"        Acceptance command (repeatable)
  --priority low|normal|high

Examples:
  scripts/task-new.sh a A-001 "Implement feature X"
  scripts/task-new.sh b B-010 "Refactor module Y" --priority high --notes "Keep diff minimal."
EOF
}

ROLE="${1:-}"
TASK_ID="${2:-}"
TITLE="${3:-}"
CREATED_BY="human"

if [[ -z "$ROLE" || -z "$TASK_ID" || -z "$TITLE" ]]; then
  usage >&2
  exit 1
fi

shift 3
if [[ $# -gt 0 && "${1:-}" != --* ]]; then
  CREATED_BY="$1"
  shift
fi

NOTES=""
NOTES_STDIN="false"
PRIORITY="normal"
ACCEPTANCE=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes)
      NOTES="${2:-}"
      shift 2
      ;;
    --notes-stdin)
      NOTES_STDIN="true"
      shift
      ;;
    --acceptance)
      ACCEPTANCE+=("${2:-}")
      shift 2
      ;;
    --priority)
      PRIORITY="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$NOTES_STDIN" == "true" ]]; then
  echo "Enter notes. Finish with Ctrl-D." >&2
  if [[ -n "$NOTES" ]]; then
    NOTES="${NOTES}"$'\n'"$(cat)"
  else
    NOTES="$(cat)"
  fi
fi

yaml_quote() {
  python3 - <<'PY' "$1"
import json
import sys
print(json.dumps(sys.argv[1]))
PY
}

TITLE_Q="$(yaml_quote "$TITLE")"
CREATED_BY_Q="$(yaml_quote "$CREATED_BY")"

if [[ -z "$NOTES" ]]; then
  NOTES="TODO: describe requirements and context."
fi

NOTES_INDENTED="$(printf '%s\n' "$NOTES" | sed 's/^/  /')"

TASK_PATH=".agent-queue/inbox/$ROLE/$TASK_ID.yaml"
if [[ -e "$TASK_PATH" ]]; then
  echo "Task already exists: $TASK_PATH" >&2
  exit 1
fi

mkdir -p ".agent-queue/inbox/$ROLE"

{
  echo "id: $TASK_ID"
  echo "role: $ROLE"
  echo "title: $TITLE_Q"
  echo "created_by: $CREATED_BY_Q"
  echo "state: ready"
  echo "priority: $PRIORITY"

  if [[ ${#ACCEPTANCE[@]} -eq 0 ]]; then
    echo "acceptance: []"
  else
    echo "acceptance:"
    for cmd in "${ACCEPTANCE[@]}"; do
      CMD_Q="$(yaml_quote "$cmd")"
      echo "  - $CMD_Q"
    done
  fi

  echo "notes: |"
  echo "$NOTES_INDENTED"
  echo "questions: []"
  echo "answers: []"
  echo "host_commands: []"

  echo "attempts_agent: 0"
  echo "attempts_host: 0"
  echo "last_agent_run_at: \"\""
  echo "last_agent_exit: \"\""
  echo "last_host_run_at: \"\""
  echo "last_host_exit: \"\""
  echo "last_host_log: \"\""

  echo "result: \"\""
  echo "error: \"\""
} > "$TASK_PATH"

echo "Created task: $TASK_PATH"
