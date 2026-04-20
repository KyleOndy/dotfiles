You are decomposing an implementation plan into discrete, executable tasks.

## Inputs

### Spec

{{SPEC}}

### Plan

{{PLAN}}

### Existing TASKS.md (revise rather than recreate if present)

{{EXISTING_TASKS}}

## Required deliverable

Write a task list to `./TASKS.md` and one `./tasks/<ID>-<slug>/PLAN.md` per task.

### TASKS.md format

A markdown checklist. Each line MUST follow this exact shape:

```
- [ ] T0N <slug>: Free-form task title
```

where:

- `T0N` is a stable ID, zero-padded to two digits (`T01`, `T02`, ..., `T99`). Pick the next available IDs sequentially. Do NOT renumber existing tasks if revising.
- `<slug>` is a lowercase-hyphenated short name derived from the title (e.g. `fix-auth-bypass`, `add-toml-loader`). Maximum 40 characters. No leading or trailing hyphens. Letters, digits, and hyphens only.
- The title is a freeform sentence describing what this task accomplishes.

Example:

```
- [ ] T01 add-toml-loader: Add TOML config loader alongside YAML
- [ ] T02 wire-up-loader: Wire the new loader into application startup
- [ ] T03 migrate-fixtures: Convert YAML test fixtures to TOML
```

### Per-task PLAN.md format

For each task in `TASKS.md`, write a file at `./tasks/<ID>-<slug>/PLAN.md` containing:

- **Intent** — one sentence on what this task accomplishes.
- **Inputs** — files and prior task outputs this task depends on.
- **Steps** — ordered, concrete actions the builder will take.
- **Files touched** — expected paths to be modified or created.
- **Acceptance** — runnable checks (commands or observable outcomes) that prove this task works.
- **Out of scope** — what this task does NOT do (often pushed to a later task).

## Rules

- A single task MUST fit in one agent context window. If a task is large, split it.
- Tasks should be roughly the size a human engineer could complete in 30 minutes to 2 hours.
- Order tasks by dependency. The builder will pick them top-down.
- Each task plan must include enough context that a fresh agent (no memory of prior tasks) can complete it.
- Do NOT write any code in `TASKS.md` or task plans.
- Do NOT modify `SPEC.md` or `PLAN.md` — they are inputs.
- If revising, preserve task IDs of existing tasks even if you reorder, retitle, or split them.

When finished, write `TASKS.md` plus one `PLAN.md` per task, then stop.
