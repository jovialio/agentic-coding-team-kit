# Task lifecycle — end to end

This describes the lifecycle of a task from creation to completion.

---

## 0) Setup

- Create queue directories
- Start watchers

---

## 1) Human creates a task

Create a YAML file in `.agent-queue/inbox/<role>/`.

Recommended: use `scripts/task-new.sh`.

---

## 2) Role watcher picks up the task

- Moves task to `.agent-queue/doing/<role>-<filename>`
- Runs Codex with `prompts/codex-<role>.txt`

---

## 3) Agent runs and updates code + YAML

Outcomes:

### A) Needs human input
- Agent appends to `questions:`
- Sets `state: waiting_for_human`
- Task stays in `doing/`

To resume:
- Human appends to `answers:` and sets `state: ready`
- Move task back to inbox (or use `scripts/task-resume.sh`)

### B) Needs host-run
- Agent sets `state: needs_host_run`
- Populates `host_commands:`
- Task is moved to `.agent-queue/host-run/<role>/`

Host-run watcher:
- runs allowlisted host_commands
- appends `answers:` summary
- clears `host_commands`
- sets `state: ready`
- requeues to inbox

Fail-loud rule (recommended):
- If a task is present in the **explicit** host-run queue but is not runnable (bad `state`, missing/empty `host_commands`, or non-allowlisted commands), move it to `failed/` with:
  - `state: waiting_for_human`
  - `error: invalid_host_commands`
  - a crisp `questions:` message

### C) Completed
- On success, role watcher moves task to `done/`
- On failure, moves to `failed/` and sets `error`

---

## 4) Interrupts

If you stop a watcher while it is processing a task:
- watcher should mark `interrupted=true` + reason
- move the task to `failed/` (or requeue, depending on your policy)
