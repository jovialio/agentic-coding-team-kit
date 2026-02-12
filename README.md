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
- `docs/WORKTREES.md` — how/why to use one git worktree per role

### Scripts
- `scripts/start-watchers.sh` — start/stop/status wrapper (process groups + log tails + lock status)
- `scripts/agent-watch.sh` — per-role watcher (runs Codex on tasks)
- `scripts/host-run-watch.sh` — runs allowlisted host commands for `needs_host_run` tasks
- `scripts/queue-status.sh` — prints queue snapshot + ages
- `scripts/queue-doctor.sh` — diagnose stuck queues (`--fix` applies safe auto-fixes)

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

### Install notes (conflicts + safe upgrades)

By default, the installer is **conservative**:
- Without `--force`, it will **not overwrite** existing files in the target repo.
- This is safer, but it can produce a **partial install/upgrade** if your repo already has files with the same paths (e.g. `scripts/agent-watch.sh`, `docs/AGENTS-SPEC.md`).

Recommended workflow (safe):
1) Install on a fresh branch
2) Review the diff
3) Merge

Example:
```bash
cd /path/to/your/repo
git checkout -b chore/agentic-kit-install

# from the kit directory:
./install.sh --target /path/to/your/repo --init

cd /path/to/your/repo
git status
git diff
```

If you *intend* to replace existing kit files (overwrite), re-run with `--force`:
```bash
./install.sh --target /path/to/your/repo --init --force
```

If you want to keep some kit files but not others, prefer resolving conflicts explicitly:
- rename your existing scripts, or
- selectively copy/merge only the files you want.

Also note: the installer appends a `.gitignore` snippet that ignores most `.agent-queue/**` runtime state (including `inbox/`). If you want tasks committed for audit/history, edit the added snippet accordingly.

What the installer does:
- copies `scripts/`, `docs/`, `prompts/` into the target repo
- writes `AGENTIC_TEAM_KIT.md` into the target repo (reference copy)
- appends `.gitignore` runtime ignores (locks/logs/run dirs)

---

## Team onboarding (copy/paste quickstart)

This section is meant to be pasted into your team chat / internal wiki.

### 0) Install

```bash
# from this kit directory
./install.sh --target /path/to/your/repo --init
```

### 1) (Recommended) set up one worktree per role

```bash
cd /path/to/your/repo
./scripts/worktree-setup.sh a,b
```

Run watchers from their role worktrees (`repo-a/`, `repo-b/`) so each role has a clean git status.

### 2) Start watchers

From the repo root (or use start-worktree-watchers):

```bash
./scripts/start-watchers.sh start
./scripts/start-watchers.sh status --tail 5
```

### 3) Create a task

```bash
./scripts/task-new.sh a A-001 "Implement feature X" --priority high
```

Watch for progress:
- `.agent-queue/doing/`
- `.agent-queue/done/`
- `.agent-queue/failed/`

### 4) Host-run commands (outside the sandbox)

If a task needs a host-only command (Docker, DB integration tests, local tooling):
- set `state: needs_host_run`
- set `host_commands: [...]`
- **do not move the YAML yourself** in the recommended flow; the role watcher routes it to `.agent-queue/host-run/<role>/`.

### 5) Unstick the system in <60s

First step:

```bash
./scripts/queue-status.sh
./scripts/queue-doctor.sh
```

If it’s safe to auto-fix:

```bash
./scripts/queue-doctor.sh --fix
```

Locks are stored under:
- `.agent-queue/logs/.locks/`

---

## How it works (conceptual)

### Coordinator (main agent) + role agents

This system is designed around a **single coordinator** (a “main agent” like R2D2, or a human operator) that manages work by writing YAML tasks into role inboxes.

- The **coordinator** does *not* need to run Codex directly.
- The coordinator:
  - creates tasks in `.agent-queue/inbox/<role>/`
  - monitors progress (`queue-status`, watcher logs)
  - answers questions when a task pauses (`state: waiting_for_human`)
  - requeues tasks after answers / fixes
  - runs `queue-doctor --fix` to recover from common stuck states
- **Role agents** (one per role) are “workers” that run via watchers and only touch the code in their scope.
- The **host-run watcher** is a special worker for commands that must run outside the agent sandbox (Docker/DB/integration tests, etc.).

Flow (high level):
```mermaid
flowchart TD
  C[Coordinator (main agent / operator)] -->|Create task YAML| I[.agent-queue/inbox/&lt;role&gt;/]

  I --> W[Role watcher (agent-watch.sh &lt;role&gt;)]
  W --> D[.agent-queue/doing/]
  D --> X[Codex runs with role prompt]
  X --> D

  D -->|state: waiting_for_human| H[Pause for coordinator answer]
  H -->|answers + state: ready + resume| I

  D -->|state: needs_host_run + host_commands| Q[.agent-queue/host-run/&lt;role&gt;/]
  Q --> HR[Host-run watcher (host-run-watch.sh)]
  HR -->|append answers + state: ready + requeue| I

  D -->|success| DONE[.agent-queue/done/]
  D -->|failure| FAIL[.agent-queue/failed/]

  C -.->|Monitor / unstick| S[queue-status.sh / queue-doctor.sh]
  S -.-> I
  S -.-> D
  S -.-> Q
```

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

If a task is present in the **explicit** host-run queue but is not runnable (bad `state`, missing/empty `host_commands`, or non-allowlisted commands), the watcher **fails loud**:
- moves the task to `failed/`
- sets `state: waiting_for_human`
- sets `error: invalid_host_commands`
- appends a crisp `questions:` message

This prevents "silent stuck" tasks sitting in `host-run/` forever.

---

## Start / stop / status

From your repo root (after install):

```bash
./scripts/start-watchers.sh start
./scripts/start-watchers.sh status --tail 5
./scripts/start-watchers.sh stop
```

## How to monitor what Codex / watchers are doing

There are three layers of visibility:

### 1) Queue folders (ground truth)

```bash
# In-progress tasks (and waiting_for_human)
ls -la .agent-queue/doing/

# Tasks waiting to start (per role)
find .agent-queue/inbox -maxdepth 2 -type f -name "*.y*ml" -print

# Tasks queued for host-run (integration tests, docker, playwright/pytest-style gates)
find .agent-queue/host-run -maxdepth 2 -type f -name "*.y*ml" -print

# Completed / failed
ls -la .agent-queue/done/
ls -la .agent-queue/failed/
```

Tip: open the YAML in `.agent-queue/doing/` to see the exact task context, current `state:`, questions/answers, attempts, and any error.

### 2) Queue snapshot + ages (recommended)

```bash
./scripts/queue-status.sh
```

This prints `doing`, `inbox`, `host-run`, `failed`, `done` with file ages so you can spot stuck work quickly.

### 3) Watcher logs (live progress)

Logs are written under:
- `.agent-queue/logs/agent-<role>.log`
- `.agent-queue/logs/host-run.log`

Tail them:
```bash
# Role watcher(s) (Codex)
tail -n 200 -f .agent-queue/logs/agent-a.log
# tail -n 200 -f .agent-queue/logs/agent-b.log

# Host-run watcher
tail -n 200 -f .agent-queue/logs/host-run.log
```

Note: `host-run-watch.sh` may also write an internal log file named `host-run-watch.log` in the same directory. If `host-run.log` is empty, try:
```bash
tail -n 200 -f .agent-queue/logs/host-run-watch.log
```

Optional (recommended): start watchers from per-role worktrees:

```bash
./scripts/worktree-setup.sh a,b
./scripts/start-worktree-watchers.sh start a,b
./scripts/start-worktree-watchers.sh status
```

Worktrees explained (incl. why `.agent-queue/done/` stays local):
- `docs/WORKTREES.md`

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

# NOTE: In the recommended flow, the role watcher routes the task into
# .agent-queue/host-run/<role>/ after Codex exits.
# If you are doing this manually, you can move it into host-run:
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

### Common blockers (quick fixes)

#### 1) File permissions / executability

Symptoms:
- `Permission denied` when running scripts
- watcher logs show `bash: ./scripts/...: Permission denied`

Fix:
```bash
chmod +x install.sh scripts/*.sh
```

Also ensure the queue dirs are writable by your user:
```bash
mkdir -p .agent-queue .agent-lock
# if needed:
# sudo chown -R "$USER" .agent-queue .agent-lock
```

#### 2) Missing / broken Python dependencies

Symptoms:
- watcher exits immediately
- log shows `ERROR: PyYAML is not installed for python3`

Fix:
```bash
python3 -c "import yaml; print('PyYAML OK')"
# Debian/Ubuntu:
apt-get install -y python3-yaml
# or:
pip install pyyaml
```

#### 3) Codex CLI not installed / not on PATH / not authenticated

Symptoms:
- tasks move to `failed/` with `error: codex_not_found`
- watcher log shows `codex: command not found`

Fix:
```bash
codex --version
# If your environment requires auth, confirm it is logged in:
# codex login status
```

#### 4) Role / env var mismatch (AGENT_ROLES)

Symptoms:
- tasks fail validation with “Invalid role: …”

Fix:
- If you add roles beyond `a,b`, start watchers with:
  ```bash
  AGENT_ROLES=a,b,review ./scripts/start-watchers.sh start
  ```
- Ensure your tasks’ `role:` field matches one of the configured roles.

#### 5) Tasks stuck in the queue

First step:
```bash
./scripts/queue-status.sh
./scripts/queue-doctor.sh
# safe auto-fixes:
./scripts/queue-doctor.sh --fix
```

Notes:
- `state: waiting_for_human` will intentionally pause in `doing/` until you answer and resume.
- `state: needs_host_run` must have non-empty `host_commands:` and the command must match the allowlist.

Start here (recommended):

```bash
./scripts/queue-status.sh
./scripts/queue-doctor.sh
# safe auto-fixes:
./scripts/queue-doctor.sh --fix
```

Key runtime locations:
- Queue: `.agent-queue/{inbox,doing,host-run,done,failed}/`
- Logs: `.agent-queue/logs/`
- Shared locks: `.agent-queue/logs/.locks/`

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
