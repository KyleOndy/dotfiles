You are writing a specification for an engineering task.

The spec is a contract between the user and downstream agents. It defines what to build, what NOT to build, and how completion is verified. The spec is the source of truth; code is the generated artifact.

## Inputs

### Description from user

{{DESCRIPTION}}

### Linear ticket context (if available)

{{LINEAR}}

### Existing SPEC.md (revise rather than replace if present)

{{EXISTING_SPEC}}

## Required deliverable

Write a complete spec to `./SPEC.md`. Use `## ` H2 headers for every section, spelled exactly as shown below:

## Outcomes

Concrete completion criteria. What does the user observe when this is done?

## In scope

Bulleted list of what this work covers.

## Out of scope

Bulleted list of what this work does NOT cover. Be aggressive about closing doors; downstream agents will expand scope unless told not to.

## Constraints & assumptions

Tech stack, perf bars, API limits, anything not obvious from the codebase.

## Prior decisions

Choices already made that downstream agents must respect (DB schema, libraries, naming conventions).

## Verification criteria

Specific acceptance checks. Each one should be runnable or observable. The verifier will check against these.

## Rules

- Do NOT write code. This is a spec, not an implementation.
- Do NOT include implementation steps. Those go in `PLAN.md` (a later phase).
- Be concrete. Vague specs produce vague code. Use exact identifiers, file paths, command names where they exist.
- If the description is ambiguous on something material, list it under a final `## Open questions` section rather than guessing.
- If revising an existing spec, preserve sections that still hold and only edit what changed.

When finished, write `SPEC.md` and stop. Do not start work on the implementation.
