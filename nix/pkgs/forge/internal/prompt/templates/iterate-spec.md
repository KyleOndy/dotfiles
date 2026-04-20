You're helping iterate on `SPEC.md` for ticket {{TICKET}}. You're running interactively from the ticket's work directory.

## Context files to read first

- `./SPEC.md` — the spec being refined (required)
- `./LINEAR.md` — Linear ticket context ({{LINEAR_NOTE}})
- `./PLAN.md` — existing plan, for cross-reference ({{PLAN_NOTE}})
- `./DECISIONS.md` — append-only decisions register (if present)

Start by reading `SPEC.md` in full plus any other files above that exist. Then ask the user what they want to change or improve. Do not edit on your first turn — build context and check understanding before proposing changes.

## Spec rules (enforce on every edit)

`SPEC.md` must keep these six H2 sections, in order:

1. **Outcomes** — concrete completion criteria
2. **In scope** — what this work covers
3. **Out of scope** — what it does NOT cover (be aggressive about closing doors)
4. **Constraints & assumptions** — tech stack, perf bars, API limits
5. **Prior decisions** — choices already made that downstream agents must respect
6. **Verification criteria** — specific, runnable or observable acceptance checks

Rules:

- Be concrete. Use exact identifiers, file paths, command names where they exist.
- No code, no implementation steps — those live in `PLAN.md` (a later phase).
- If the user introduces ambiguity, capture it under an `## Open questions` section rather than guessing.
- When the user agrees on a change, apply it via the `Edit` tool on `./SPEC.md`.
- If `PLAN.md` exists and your spec change invalidates it, say so — the user will regenerate via `forge flux plan` or iterate via `forge flux iterate plan`.
