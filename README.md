# Agentic coding team kit (file-based queue)

A reusable template for running multiple Codex CLI agents as a **small coding team** using:
- a shared YAML task queue on disk
- one watcher per role (e.g. `a`, `b`, `review`)
- an optional **host-run** watcher for commands that must run outside the agent sandbox

This kit is **repo-agnostic**. It contains no product/app assumptions.

Recent best practices (battle-tested):
- Prefer **one git worktree per role** to prevent cross-role git conflicts and “dirty tree” stalls.
- Treat environment-limited gates (Docker/DB/network) as first-class: avoid retry loops; shrink the gate or queue a host-run.
- Merge role work via an **integration branch** first (not straight to `main`).

---

## What this kit includes

### Docs
- `docs/AGENTS-OPERATOR.md` — day-to-day runbook
- `docs/AGENTS-SPEC.md` — invariants + state machine
- `docs/AGENTS-FLOW.md` — end-to-end lifecycle

### Scripts
- `scripts/start-watchers.sh` — start/stop/status wrapper (process groups + log tails + lock status)
- `scripts/agent-watch.sh` — per-role watcher (runs Codex on tasks)
- `scripts/host-run-watch.sh` — runs allowlisted host commands for `needs_host_run` tasks

Task/YAML helpers:
- `scripts/task-new.sh`
- `scripts/task-update.py`
- `scripts/task-validate.py`
- `scripts/task-sanitize.py`
- `scripts/task-resume.sh`

Host-run safety:
- `scripts/host-command-allowlist.py` — single source of truth for allowed host-run commands

### Prompts
- `prompts/codex-a.txt`
- `prompts/codex-b.txt`

You can add more roles by creating `prompts/codex-<role>.txt`.

---

## Prerequisites

1) **Python + PyYAML** (required)

```bash
python3 -c "import yaml; print('PyYAML OK')"
```

Install:
- Debian/Ubuntu: `apt-get install -y python3-yaml`
- or: `pip install pyyaml`

2) **Codex CLI**

```bash
codex --version
```

---

## Install into a repo

From this kit directory:

```bash
./install.sh --target /path/to/your/repo --init
```

Options:
- `--force` overwrite existing files in the target
- `--init` create `.agent-queue/**` and `.agent-lock/` directories

What the installer does:
- copies `scripts/`, `docs/`, `prompts/` into the target repo
- writes `AGENTIC_TEAM_KIT.md` into the target repo (reference copy)
- appends `.gitignore` runtime ignores (locks/logs/run dirs)

---

## How it works (conceptual)

### The queue
Tasks are YAML files stored under:

```text
.agent-queue/inbox/<role>/
```

Role watchers:
- pick tasks from inbox
- move them into `doing/`
- run Codex with the role prompt
- route the task based on `state:`

### State machine
Allowed task `state:` values:
- `ready` — role watcher may run
- `waiting_for_human` — pauses in `doing/` until a human answers
- `needs_host_run` — host-run watcher must run `host_commands`
- `blocked` — external dependency

### Host-run safety
The host-run watcher only executes commands that match an allowlist:
- `scripts/host-command-allowlist.py`

If a task has `host_commands` that do not match the allowlist, the watcher requeues it back to inbox with:
- `error=host_command_not_allowed`

---

## Start / stop / status

From your repo root (after install):

```bash
./scripts/start-watchers.sh start
./scripts/start-watchers.sh status --tail 5
./scripts/start-watchers.sh stop
```

Optional (recommended): start watchers from per-role worktrees:

```bash
./scripts/worktree-setup.sh a,b
./scripts/start-worktree-watchers.sh start a,b
./scripts/start-worktree-watchers.sh status
```

---

## Create a task

```bash
./scripts/task-new.sh a A-001 "Implement feature X" --priority high
```

Then watch `.agent-queue/doing/` and `.agent-queue/done/` for progress.

---

## Answer a question (waiting_for_human)

If a task is stuck in `state: waiting_for_human`, it will be in:
- `.agent-queue/doing/<role>-<task>.yaml`

Add your answer and resume:

```bash
python3 scripts/task-update.py --file <task.yaml> \
  --append "answers=YOUR ANSWER" \
  --set state=ready \
  --set error=""

./scripts/task-resume.sh <task.yaml> --ready
```

---

## Trigger a host-run command

Example: queue a host-run command for a task:

```bash
python3 scripts/task-update.py --file <task.yaml> \
  --set state=needs_host_run \
  --set-json 'host_commands=["make test"]'

mv <task.yaml> .agent-queue/host-run/<role>/
```

The host-run watcher will:
- execute the allowlisted command
- append a short result to `answers:`
- clear `host_commands`
- set `state: ready`
- requeue the task back to inbox

---

## Extending roles

To add a new role (e.g. `review`):
1) Create `prompts/codex-review.txt`
2) Create directories:

```bash
mkdir -p .agent-queue/inbox/review .agent-queue/host-run/review
```

3) Start watchers with roles:

```bash
AGENT_ROLES=a,b,review ./scripts/start-watchers.sh start
```

---

## Extending the host-run allowlist

Edit:
- `scripts/host-command-allowlist.py`

Guidelines:
- Keep patterns narrow and deterministic.
- Avoid allowing arbitrary shells.
- Prefer exact commands (or exact script/spec paths).

---

## Troubleshooting

### Task not being picked up
- Is it in `.agent-queue/inbox/<role>/`?
- Is `state: ready`?
- Validate YAML:
  ```bash
  python3 scripts/task-validate.py --file <task.yaml>
  ```

### Watchers not running
- Check status:
  ```bash
  ./scripts/start-watchers.sh status --tail 20
  ```

### Host-run task not executing
- Is it in `.agent-queue/host-run/<role>/`?
- Is `state: needs_host_run` and `host_commands` non-empty?
- Does the command match `scripts/host-command-allowlist.py`?

---

## Security notes

- Do not put secrets into task YAML.
- Treat `host_commands` as production-grade risk: keep allowlist strict.
- Prefer read-only, deterministic commands for host-run.
