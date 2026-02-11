#!/usr/bin/env bash
set -euo pipefail

# worktree-setup.sh
#
# Create one git worktree per role and share runtime queue folders between them.
#
# Why:
# - each role has a clean git status (fewer conflicts)
# - agents stop stalling on unrelated modified files
# - runtime task queue stays shared so roles can collaborate
#
# Usage:
#   ./scripts/worktree-setup.sh a,b
#
# Result (default):
#   ../<repo-name>-a
#   ../<repo-name>-b
#
# Notes:
# - Keeps `.agent-queue/done/` local (do not symlink) to avoid issues when repos track done/.
# - Symlinks only runtime dirs: inbox/ doing/ failed/ host-run/ playwright/ pytest/ archived/ logs/ run/ host-logs/ artifacts/ trash/

ROLE_LIST="${1:-a,b}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_NAME="$(basename "$REPO_ROOT")"

IFS=',' read -r -a roles <<<"$ROLE_LIST"

cd "$REPO_ROOT"

# Ensure baseline runtime dirs exist in the main worktree
mkdir -p .agent-queue/{inbox,doing,failed,host-run,playwright,pytest,archived,logs,run,host-logs,artifacts,trash}
mkdir -p .agent-lock

# Create per-role inbox/host-run
for r in "${roles[@]}"; do
  r="${r// /}"
  [[ -n "$r" ]] || continue
  mkdir -p ".agent-queue/inbox/$r" ".agent-queue/host-run/$r"
  wt_path="../${REPO_NAME}-${r}"
  branch="worktree/${r}"

  if [[ -d "$wt_path" ]]; then
    echo "[skip] worktree exists: $wt_path"
  else
    echo "[add] worktree $r -> $wt_path (branch $branch)"
    git worktree add "$wt_path" -b "$branch" HEAD
  fi

  # In the worktree, keep done/ local but link runtime dirs back to main.
  (
    cd "$wt_path"

    # Ensure .agent-queue exists and done/ is local
    mkdir -p .agent-queue/done

    shared_root="$REPO_ROOT/.agent-queue"
    for sub in inbox doing failed host-run playwright pytest archived logs run host-logs artifacts trash; do
      rm -rf ".agent-queue/$sub" 2>/dev/null || true
      ln -s "$shared_root/$sub" ".agent-queue/$sub"
    done

    # Optional: share lock path
    mkdir -p .agent-lock
    shared_lock_root="$REPO_ROOT/.agent-lock"
    ln -s "$shared_lock_root/contracts.lock" .agent-lock/contracts.lock 2>/dev/null || true
  )

done

echo "[ok] worktrees ready for roles: $ROLE_LIST"
