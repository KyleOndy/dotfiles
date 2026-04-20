You are composing today's status update for ticket {{TICKET}}.

This will be saved as a draft to disk. The user reviews and posts it manually to Linear later. Do NOT post anything yourself, anywhere.

## Inputs

### Spec

{{SPEC}}

### Tasks state (TASKS.md)

{{TASKS}}

### Per-task summaries

{{TASK_SUMMARIES}}

### Per-task verdicts

{{TASK_VERDICTS}}

### Most recent prior status (for delta context)

{{PRIOR_STATUS}}

## Required deliverable

Write a status update to `./{{DATE}}-status.md` (relative to the ticket's root dir, NOT the `work/` dir). Use this format exactly. It matches Kyle's existing convention so `/linear:status-update` can pick it up cleanly:

```
# {{TICKET}} Status -- <Day, Month DDth>

tl;dr: [one sentence]

## Blockers

- [only if real]

## Open questions

- [only if real]

## Done since last update

- [bulleted, with task IDs and one-line summaries]

## What works

[current state of the work, as a paragraph or list]

## What doesn't work

- [known issues from FAIL verdicts or unresolved findings]

## Next

1. [ordered, concrete next steps]

---

## Technical details

[Full technical context: branch names, file paths touched, anything the verifier flagged that needs human follow-up.]
```

Omit empty sections. Match the writing style: short declarative sentences, no corporate tone, no AI-isms, no emojis, no em dashes (use commas, periods, parens instead).

When finished, write the file and stop. Do NOT post to Linear, Slack, GitHub, or anywhere else.
