---
description: Exhaustive upfront research - gather information before acting
---

# Research

Read-only investigation. No file modifications except notes.

## Rules

1. **Do not modify code.** Read, search, web search, test hypotheses. No edits.
2. **Take your time.** This phase is allowed to burn tokens. Thoroughness over speed.
3. **Write findings to notes.md** in the ticket dir (`~/work/tickets/<id>/notes.md`).
4. **Cite everything** with file:line references or URLs.
5. **Test hypotheses** before stating them as facts. Run commands, read output, verify.

## Tools you can use

- `read` — source code, configs, logs
- `bash` — diagnostic commands (grep, find, curl, kubectl, etc.)
- `grep` — search patterns
- Web search — external docs, prior art, API references

## Output format

When presenting findings:

```
## Summary
(one sentence)

## Details
(specific facts with file:line citations)

## Evidence
(relevant code, error messages, command output)

## Recommended Next Steps
(options with tradeoffs)
```

## Transition

When research is complete, say so and propose moving to the plan phase. Don't start planning without explicit approval.

If you discover something that should be a seed, plant it: `c seed plant --title "..." --context "..."`.
