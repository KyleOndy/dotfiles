You are writing an implementation plan, not code.

## Inputs

### Spec

{{SPEC}}

### Existing PLAN.md (revise rather than replace if present)

{{EXISTING_PLAN}}

## Required deliverable

Write a comprehensive implementation plan to `./PLAN.md`. Use `## ` H2 headers for every section, spelled exactly as shown below:

## Approach

The chosen design at a high level. Why this and not alternatives?

## Key files

Paths to the files that will be modified or created. Reference real paths in the relevant repo, not invented ones.

## Sequence

The order of work. What depends on what?

## Risks

What could go wrong? What edge cases?

## Verification strategy

How will each spec verification criterion be exercised? Map each criterion to a specific check.

## Rules

- Do NOT write code. `PLAN.md` is for design, not implementation.
- Do NOT decompose into individual tasks yet. That's the next phase (`forge flux decompose`).
- Reference real paths and symbols. If you need to grep the codebase to find them, do so.
- If the spec is missing information you need, write what you know and add an `## Open questions` section. Do not guess.

When finished, write `PLAN.md` and stop.
