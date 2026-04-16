---
description: Create a timestamped plan with explicit assumptions
---

# Plan

Write a structured plan before executing. Plans live in `~/work/tickets/<id>/plans/`.

## Steps

1. Run `c plan "meaningful name"` to create the plan file.
2. Fill in every section of the template. The **Assumptions** section is critical; these are what trigger replanning if wrong.
3. Present the plan to the user. **Stop and wait for approval.**

## Template sections

- **Goal**: what we're trying to accomplish, specific and measurable
- **Assumptions**: load-bearing assumptions. If any are wrong, replan.
- **Risks**: what could go wrong, what we'd do about it
- **Tasks**: ordered steps, small enough to complete in 15-30 min each
- **Stop Conditions**: when we're done (success criteria) and when to abort

## Assumptions discipline

Every assumption must be:

- Stated explicitly (not implicit in the plan)
- Testable (we can verify it's true or false)
- Referenced from the tasks that depend on it

When a previous plan failed, the new plan's Background section must reference the failed assumption and the corresponding learning entry.

## Transition

After approval, move to execution. Use `/skill:execute` or just start working from the plan.
