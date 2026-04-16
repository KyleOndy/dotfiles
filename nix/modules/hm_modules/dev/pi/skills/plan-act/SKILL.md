---
description: Structured iterative development with plan-then-act cycles for complex tickets
---

# Plan-Act Mode

Use this skill when the user wants structured, iterative development with explicit planning phases.

**Key Principle: Many small plan→act cycles, not one big plan.**

## Trigger Phrases

- "let's plan this"
- "start a ticket"
- "work on CLIN-XXX"
- "/skill:plan-act" or "plan-act mode"
- "next iteration" / "new plan" / "plan B"

## Directory Structure

Tickets are stored in `~/work/tickets/CLIN-<number>/` (work) or `~/tickets/TICKET-<number>/` (personal).

```
CLIN-123/
├── plans/                          # All plans, timestamped
│   ├── 2025-01-15-09-30-initial-exploration.md
│   ├── 2025-01-15-11-45-refactor-approach.md
│   └── 2025-01-15-14-00-fix-edge-cases.md
├── YYYY-MM-DD-status.md            # Manager-facing status (polished)
├── YYYY-MM-DD-claudes-notes.md     # Raw working log (detailed)
└── todo.md                         # Current checklist (rolls across plans)
```

**No `plan.md` singular.** Plans are timestamped and versioned.

## Phase 1: Discovery (Required)

Before writing any plan:

1. **Identify ticket**: Extract from context or ask user
   - `pwd` might hint: `/Users/kondy/src/modularml/mammoth/CLIN-708/...`
   - Ask explicitly if unclear: "What ticket are we working on?"

2. **Check existing state**:
   - List `plans/` directory — how many iterations so far?
   - Read most recent plan to understand current approach
   - Read `todo.md` for outstanding items (may carry over)
   - Read `status.md` for context

3. **Determine if new plan needed**:
   - Current plan failed/needs pivot? → New plan
   - Current plan succeeded but uncovered new work? → New plan
   - First time on this ticket? → Initial plan
   - Continuing current plan? → Skip to Phase 4

4. **Clarify scope** (for this iteration):
   - What's the specific goal for THIS plan→act cycle?
   - Timebox: 30 min? 2 hours? Half day?
   - Stop condition: when do we know we're done with THIS iteration?

## Phase 2: Planning (Required)

Create new plan file: `plans/YYYY-MM-DD-HH-MM-<meaningful-name>.md`

Get timestamp: `date +"%Y-%m-%d-%H-%M"` (or use current datetime)

Name should be 2-4 words describing the approach: `initial-exploration`, `api-refactor`, `fix-race-condition`, etc.

### Plan Template

```markdown
# Plan: [One sentence goal]

**Created:** YYYY-MM-DD HH:MM  
**Approach:** [brief description of strategy]
**Timebox:** [estimated duration]

## Goal

[Clear, specific outcome for THIS iteration]

## Success Criteria

1. [ ] Criterion 1
2. [ ] Criterion 2

## Background

[Why this approach? What did we learn from previous iteration?]

## Assumptions

- [Load-bearing assumptions]

## Risks & Mitigations

| Risk                  | Likelihood   | Mitigation            |
| --------------------- | ------------ | --------------------- |
| [What could go wrong] | High/Med/Low | [How we'll handle it] |

## Task Breakdown

1. [Task 1 - small, ~15-30 min]
2. [Task 2 - small]
3. [Task 3 - small]

## Stop Conditions

- When criteria 1 and 2 are met
- If we hit [specific blocker]
- After [timebox] elapsed

## Next Plan (tentative)

[If this succeeds, what might we tackle next?]

## Notes

[Links, references, context from previous iterations]
```

**STOP HERE.** Present plan and ask: "Proceed with this plan, or revise?"

## Phase 3: Todo Sync (Required)

Before acting, update `todo.md`:

1. Carry over incomplete items from previous plan (if any)
2. Add new tasks from this plan
3. Mark what's already done

```markdown
# Todo: [Ticket]

## Active (from current plan)

- [ ] Task A (from 2025-01-15-14-00-fix-edge-cases)
- [ ] Task B

## Backlog (from previous plans)

- [ ] Deferred task from earlier

## Done

- [x] Task from previous iteration (2025-01-15 morning)
```

## Phase 4: Execution Loop (Act Mode)

Use "/mode act" or proceed with execution mindset:

**One task at a time:**

1. Pick next "Active" task from todo.md
2. Mark "In Progress" in todo.md (with timestamp)
3. Execute the task
4. Mark "Done" in todo.md (with timestamp)
5. Update status.md with findings
6. **STOP. Ask: "Continue this plan, or pause/replan?"**

**Decision points:**

- **Going well?** → Continue with next task from current plan
- **Hit unexpected snag?** → Assess: fix inline, or abort and new plan?
- **Plan invalidated?** → **STOP.** New plan needed (go to Phase 2)
- **Done with criteria?** → Validate (Phase 5)

## Phase 5: Validation & Decision

After success criteria met:

- [ ] Verify criteria from THIS plan
- [ ] Update status.md with "what worked"
- [ ] Append to claudes-notes.md with technical details
- [ ] **Decision: More work needed?**
  - **Yes** → Create new plan (Phase 2, timestamped)
  - **No (ticket done)** → Final status update, close out
  - **Unclear** → Research/Discovery (Phase 1)

## Typical Flow Example

```
09:30 - Create plans/2025-01-15-09-30-initial-approach.md
09:35 - Execute → hit unexpected API limitation
10:15 - **Abort.** Create plans/2025-01-15-10-15-alternate-api.md
10:20 - Execute → success on core task
11:00 - **Validate.** Criteria met.
11:05 - Create plans/2025-01-15-11-05-handle-edge-cases.md
...
```

## Session Management

**Label points (/tree):**

- After each plan is written (Shift+L "plan: <name>")
- After successful execution completes
- Before starting a risky new approach

**Fork (/fork) for experiments:**

- "what if we tried X instead?" → Fork, try, merge or discard

**Compact (/compact):**

- Context filling up (80%+)? Compact with summary: "Plans 1-3 completed, current working on plan 4"

## Emergency Escape Hatches

- **"Just do it"** → Switch to `/mode code`, abandon plan structure
- **"This plan is wrong"** → Stop mid-execution, write new plan with learnings
- **"Too much process"** → `/skill:none`, adapt to user's actual workflow

## Anti-Patterns

❌ **One giant plan** → Many small plans that pivot based on learning  
❌ **Plan in head** → Always write to `plans/YYYY-MM-DD-HH-MM-name.md`  
❌ **Keep going when wrong** → Abort and replan when assumptions fail  
✅ **Commit-then-confirm** → Write plan, ask approval, THEN execute
