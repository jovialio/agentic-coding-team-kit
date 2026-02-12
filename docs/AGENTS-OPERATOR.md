# Operator runbook — agentic coding team

This is the day-to-day guide.

See also:
- Spec/invariants: `docs/AGENTS-SPEC.md`
- Lifecycle: `docs/AGENTS-FLOW.md`

---

## Prerequisites

### PyYAML (required)

```bash
python3 -c "import yaml; print('PyYAML OK')"
```

Install:
- Debian/Ubuntu: `apt-get install -y python3-yaml`
- or: `pip install pyyaml`

### Coding agent runner (Codex or Claude Code)

You need a runner installed and on PATH.

- **Codex CLI**: `codex --version`
- **Claude Code CLI**: `claude --version`

Select runner at runtime via env var:
```bash
# default is codex
./scripts/start-watchers.sh start

# use Claude Code
AGENT_RUNNER=claude ./scripts/start-watchers.sh start
```

---

## Queue layout

```text
.agent-queue/
  inbox/
    a/
    b/
  doing/
  done/
  failed/
  host-run/
    a/
    b/
  logs/
  run/
.agent-lock/
```

---

## Optional: role worktrees (recommended for FE/BE)

If two roles work on different folders (e.g. frontend vs backend), the cleanest way to avoid git conflicts and “dirty-tree” stalls is to use **one git worktree per role**.

High-level idea:
- Each role gets its own checkout directory (clean git status).
- All roles share the same **runtime queue** (`inbox/doing/failed/host-run/logs/...`).
- Keep `.agent-queue/done/` local (often tracked in some repos); only symlink runtime folders.

A typical layout:
```text
repo/                 # main worktree (integration/merging)
repo-a/               # role a worktree
repo-b/               # role b worktree
```

For worktrees, run:
- role watcher `a` from `repo-a/`
- role watcher `b` from `repo-b/`
- host-run watcher from either (but ensure it sees the shared runtime queue)

See: `scripts/worktree-setup.sh` and `scripts/start-worktree-watchers.sh`.

## Integration merge (recommended)

When roles work in separate worktrees/branches, avoid merging straight into `main`.

Suggested flow:
1) Create an integration branch from `main` (e.g. `integration/2026-02-11`)
2) Merge role branches into it (pick an order; for FE/BE we typically merge BE first, then FE)
3) Run the narrowest meaningful sanity checks (lint/unit, plus any host-run E2E you rely on)
4) Only then merge the integration branch to `main`

This reduces “half-merged” states and makes rollbacks simple.

## Start / stop / status

Start all watchers:

```bash
./scripts/start-watchers.sh start
```

Start watchers using per-role worktrees (recommended):

```bash
./scripts/start-watchers.sh start --worktrees
# or:
./scripts/start-worktree-watchers.sh start a,b
```

Status (with recent logs):

```bash
./scripts/start-watchers.sh status --tail 5
```

Stop:

```bash
./scripts/start-watchers.sh stop
```

Note: `start-watchers.sh` uses process groups (via `setsid` when available) so stop/restart won’t leave orphan child processes.

---

## Create a task

```bash
./scripts/task-new.sh a A-001 "Implement feature X" --priority high
./scripts/task-new.sh b B-001 "Refactor module Y" --priority normal
```

---

## Answer questions (waiting_for_human)

When a task is `state: waiting_for_human`, it will sit in `.agent-queue/doing/`.

1) Add answer(s) and mark ready:

```bash
python3 scripts/task-update.py --file <task.yaml> \
  --append "answers=YOUR ANSWER" \
  --set state=ready \
  --set error=""
```

2) Resume it (recommended):

```bash
./scripts/task-resume.sh <task.yaml> --ready
```

---

## Trigger host-run commands

Some commands (dockerized E2E, integration tests, local tooling) may need to run outside the agent sandbox.

To queue a host-run:

```bash
python3 scripts/task-update.py --file <task.yaml> \
  --set state=needs_host_run \
  --set-json 'host_commands=["make test"]'

# move task into host-run queue:
#   mv <task.yaml> .agent-queue/host-run/<role>/
```

Host-run watcher behavior:
- runs allowlisted commands only
- appends a short summary to `answers:`
- clears `host_commands`
- sets `state: ready`
- requeues back to `.agent-queue/inbox/<role>/`

Allowlist lives in: `scripts/host-command-allowlist.py`

---

## Validate / sanitize task YAML

Validate:
```bash
python3 scripts/task-validate.py --file <task.yaml>
```

Sanitize common type mistakes:
```bash
python3 scripts/task-sanitize.py --file <task.yaml>
```

---

## Inspect queue health

```bash
./scripts/queue-status.sh
./scripts/start-watchers.sh status --tail 5
```

## Unstick common issues (recommended)

Use the queue doctor:

```bash
./scripts/queue-doctor.sh
./scripts/queue-doctor.sh --fix
```

`--fix` performs safe auto-fixes (e.g. remove stale locks, fail-loud invalid host-run tasks, requeue tasks stranded in doing/ with state=ready when the role lock is stale).
