#!/usr/bin/env bash
set -euo pipefail

# agentic-coding-team-kit installer
# Copies scripts/docs/prompts into a target repo and optionally initializes queue directories.

usage() {
  cat <<'EOF'
Usage:
  ./install.sh --target <repo-root> [--init] [--force]

Options:
  --target DIR   Target repository root directory.
  --init         Create queue directories under the target repo.
  --force        Overwrite existing files (default: do not overwrite).

What it installs:
  - scripts/  -> <target>/scripts/
  - docs/     -> <target>/docs/
  - prompts/  -> <target>/prompts/
  - README.md -> <target>/AGENTIC_TEAM_KIT.md (reference copy)
  - Appends a .gitignore snippet for runtime queue state.

Notes:
- Requires: bash, cp (and optionally rsync).
- Requires: python3 + PyYAML to run the watchers.
EOF
}

TARGET=""
DO_INIT="false"
FORCE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --init)
      DO_INIT="true"
      shift
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "--target is required" >&2
  usage >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$SCRIPT_DIR"

if [[ ! -d "$TARGET" ]]; then
  echo "Target does not exist: $TARGET" >&2
  exit 1
fi

copy_dir() {
  local src="$1" dest="$2"
  mkdir -p "$dest"

  if command -v rsync >/dev/null 2>&1; then
    # Avoid copying runtime/editor caches into target repos.
    # rsync does NOT respect .gitignore automatically.
    local excludes=(
      --exclude '__pycache__/'
      --exclude '*.pyc'
      --exclude '.pytest_cache/'
      --exclude '.venv/'
      --exclude 'node_modules/'
      --exclude '.pnpm-store/'
    )

    if [[ "$FORCE" == "true" ]]; then
      rsync -a "${excludes[@]}" "$src/" "$dest/"
    else
      rsync -a --ignore-existing "${excludes[@]}" "$src/" "$dest/"
    fi
    return 0
  fi

  # Fallback: cp-based copy (less robust than rsync for merges)
  if [[ "$FORCE" == "true" ]]; then
    cp -a "$src/." "$dest/"
  else
    # Copy only if file doesn't exist.
    # (directories will be merged; files will not be overwritten)
    (cd "$src" && find . -type d -print0) | while IFS= read -r -d '' d; do
      mkdir -p "$dest/$d"
    done
    (cd "$src" && find . -type f -print0) | while IFS= read -r -d '' f; do
      # Skip caches that may exist locally (installer should be clean by default)
      case "$f" in
        */__pycache__/*|*.pyc|*/.pytest_cache/*|*/.venv/*|*/node_modules/*|*/.pnpm-store/*)
          continue
          ;;
      esac

      if [[ ! -e "$dest/$f" ]]; then
        cp -a "$src/$f" "$dest/$f"
      fi
    done
  fi
}

append_gitignore_snippet() {
  local snippet="$KIT_ROOT/.gitignore.snippet"
  local gitignore="$TARGET/.gitignore"
  local begin="# --- agentic-coding-team-kit (runtime state) ---"
  local end="# --------------------------------------------"

  [[ -f "$snippet" ]] || return 0

  if [[ -f "$gitignore" ]]; then
    if grep -qF "$begin" "$gitignore" 2>/dev/null; then
      echo "[ok] .gitignore already contains kit snippet"
      return 0
    fi
  fi

  {
    echo
    cat "$snippet"
  } >> "$gitignore"

  echo "[ok] appended runtime ignores to .gitignore"
}

# Copy files
copy_dir "$KIT_ROOT/scripts" "$TARGET/scripts"
copy_dir "$KIT_ROOT/docs" "$TARGET/docs"
copy_dir "$KIT_ROOT/prompts" "$TARGET/prompts"

# Keep a reference copy of the kit README inside the target.
if [[ "$FORCE" == "true" || ! -e "$TARGET/AGENTIC_TEAM_KIT.md" ]]; then
  cp -a "$KIT_ROOT/README.md" "$TARGET/AGENTIC_TEAM_KIT.md"
  echo "[ok] wrote $TARGET/AGENTIC_TEAM_KIT.md"
else
  echo "[skip] $TARGET/AGENTIC_TEAM_KIT.md exists (use --force to overwrite)"
fi

append_gitignore_snippet

if [[ "$DO_INIT" == "true" ]]; then
  mkdir -p \
    "$TARGET/.agent-queue/inbox/a" \
    "$TARGET/.agent-queue/inbox/b" \
    "$TARGET/.agent-queue/doing" \
    "$TARGET/.agent-queue/done" \
    "$TARGET/.agent-queue/failed" \
    "$TARGET/.agent-queue/host-run/a" \
    "$TARGET/.agent-queue/host-run/b" \
    "$TARGET/.agent-queue/playwright" \
    "$TARGET/.agent-queue/pytest" \
    "$TARGET/.agent-queue/archived" \
    "$TARGET/.agent-queue/logs" \
    "$TARGET/.agent-queue/run" \
    "$TARGET/.agent-queue/host-logs" \
    "$TARGET/.agent-queue/artifacts" \
    "$TARGET/.agent-queue/trash" \
    "$TARGET/.agent-lock"

  echo "[ok] initialized .agent-queue and .agent-lock"
fi

echo "Done. Next steps:"
echo "  1) Ensure python3 PyYAML: python3 -c 'import yaml'"
echo "  2) Start watchers: ./scripts/start-watchers.sh start"
echo "  3) Create a task: ./scripts/task-new.sh a A-001 \"First task\""
