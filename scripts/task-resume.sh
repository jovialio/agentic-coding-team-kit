#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/task-resume.sh <task.yaml> [--ready]

Moves a task back to the correct inbox folder so the role watcher can pick it up.

Options:
  --ready   Set state=ready and clear error before requeueing.
EOF
}

TASK_PATH="${1:-}"
ACTION_READY="false"

if [[ -z "$TASK_PATH" || "$TASK_PATH" == "-h" || "$TASK_PATH" == "--help" ]]; then
  usage >&2
  exit 2
fi

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ready)
      ACTION_READY="true"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

cd "$REPO_ROOT"

if [[ ! -f "$TASK_PATH" ]]; then
  echo "Task not found: $TASK_PATH" >&2
  exit 1
fi

python3 scripts/task-validate.py --file "$TASK_PATH" >/dev/null

if [[ "$ACTION_READY" == "true" ]]; then
  python3 scripts/task-update.py --file "$TASK_PATH" --set state=ready --set error="" >/dev/null || true
fi

ROLE="$(python3 - <<'PY' "$TASK_PATH"
import sys, yaml
p=sys.argv[1]
data=yaml.safe_load(open(p,'r',encoding='utf-8').read()) or {}
print((data.get('role') or '').strip())
PY
)"

if [[ -z "$ROLE" ]]; then
  echo "Missing role in task YAML" >&2
  exit 1
fi

INBOX_DIR="$REPO_ROOT/.agent-queue/inbox/$ROLE"
mkdir -p "$INBOX_DIR"

base="$(basename "$TASK_PATH")"
# Normalize: doing/<role>-TASK.yaml -> inbox/<role>/TASK.yaml
if [[ "$base" == "$ROLE-"* ]]; then
  base="${base#${ROLE}-}"
fi

DEST="$INBOX_DIR/$base"
if [[ -e "$DEST" ]]; then
  ts="$(date -u +'%Y%m%dT%H%M%SZ')"
  DEST="$INBOX_DIR/${base%.*}-$ts.${base##*.}"
fi

mv "$TASK_PATH" "$DEST"
echo "Requeued to: $DEST"
