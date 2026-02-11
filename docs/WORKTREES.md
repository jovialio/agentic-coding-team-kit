# Worktrees per role (recommended)

If two (or more) agents/roles work in parallel on the same repo, the simplest way to avoid:
- cross-role git conflicts
- “dirty tree” false alarms / stalls
- stepping on each other’s temporary files

…is to give **each role its own git worktree**, while still sharing the **runtime queue**.

## The model

- **Main worktree**: used for integration, merging, running full checks.
- **Role worktrees**: one per role (e.g. `a`, `b`, `review`), used by that role’s watcher.
- **Shared runtime queue**: roles collaborate by reading/writing the same queue folders.

### Important rule: do NOT symlink `.agent-queue/done/`

Many repos choose to **track** some (or all) files under `.agent-queue/done/` (task history).

If you replace a tracked directory with a symlink inside a worktree, git can interpret that as
“the directory was deleted / replaced”, producing lots of confusing deletions in `git status`.

So the kit’s worktree setup keeps:
- `.agent-queue/done/` **local** (normal tracked directory)

…and symlinks only the *runtime* queue folders:
- `inbox/`, `doing/`, `failed/`, `host-run/`, `playwright/`, `pytest/`, `archived/`, `logs/`, `run/`, `host-logs/`, `artifacts/`, `trash/`

## Quick start

From your repo root (after installing this kit):

```bash
./scripts/worktree-setup.sh a,b
./scripts/start-worktree-watchers.sh start a,b
```

This creates:
- `../<repo>-a` worktree on branch `kit/worktree/a`
- `../<repo>-b` worktree on branch `kit/worktree/b`

You can change the branch prefix:

```bash
BRANCH_PREFIX=worktree ./scripts/worktree-setup.sh a,b
```

## Operational tips

- Run the **host-run watcher** from the main worktree (so it sees the shared runtime queue).
- Keep merges out of `main` until both role branches are ready: use an **integration branch**.
