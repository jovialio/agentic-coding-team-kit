# Spec — agentic coding team (file queue)

This document defines invariants and the state machine that keep the system safe.

---

## Core invariants

### 1) YAML integrity
Never raw-append YAML fragments. Always mutate via a YAML-safe round-trip.

Canonical helper:
- `scripts/task-update.py`

Validate:
- `scripts/task-validate.py`

### 2) State machine is explicit
Allowed `state:` values:
- `ready` — role watcher may run
- `waiting_for_human` — human question; task stays in `doing/`
- `needs_host_run` — host-run watcher must run `host_commands`
- `blocked` — external dependency

Rules:
- `waiting_for_human` is only for real human decisions/questions.
- `needs_host_run` is only when `host_commands` is present and non-empty.

### 3) Host-run is allowlisted
Host-run watcher must only run allowlisted commands.

Single source of truth:
- `scripts/host-command-allowlist.py`

Keep allowlist patterns narrow and deterministic.

### 4) Avoid stalls on dirty git trees
In a multi-role system, unrelated files may be modified by other roles.

Rule:
- Role agents must **not** hard-stop just because `git status` is dirty.
- Only stop if you would need to edit forbidden paths, or you hit real lock/conflict.

(Worktrees-per-role is the recommended way to make this deterministic.)

### 5) Environmental gates should not cause retry loops
If a gate fails due to environment constraints (sandbox cannot access Docker/DB/network), do not keep retrying the same impossible command.

Instead:
- shrink the gate to the narrowest meaningful check, or
- queue a host-run command and continue.

### 6) Safe interruption
Stopping watchers should not strand tasks in `doing/`.

- Role watcher should trap signals and mark `interrupted=true` before moving tasks to failed.

---

## Queue + locks

Watcher locks (recommended):
- Store watcher locks under the shared runtime path: `.agent-queue/logs/.locks/`
  - This matters because with worktrees-per-role, multiple checkouts share the same runtime queue.

Primary folders:
- `.agent-queue/inbox/<role>/` — tasks waiting
- `.agent-queue/doing/` — active tasks + waiting_for_human
- `.agent-queue/host-run/<role>/` — queued host-run commands
- `.agent-queue/done/` / `.agent-queue/failed/`

Optional locks:
- `.agent-lock/` — lock directories for shared resources (if needed)

---

## Recommended task YAML schema

Required fields:
- `id`, `role`, `title`, `state`

Recommended fields:
- `priority` (low|normal|high)
- `notes` (block scalar)
- `questions`, `answers` (lists)
- `host_commands` (list of strings)
- `attempts_agent`, `attempts_host`
- `last_agent_run_at`, `last_host_run_at`
- `result`, `error`
