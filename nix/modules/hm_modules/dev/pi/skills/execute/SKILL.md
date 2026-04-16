---
description: Execute from an approved plan with frequent commits and assumption monitoring
---

# Execute

Work from the approved plan. Commit often, plant seeds for observations, monitor assumptions.

## Rules

1. **One task at a time.** Pick the next task from the plan, complete it, commit.
2. **Commit after every meaningful change** via `c ai-tooling commit -m "..."`.
3. **Plant seeds** when you notice something worth investigating later. Quick capture, resume work.
4. **Monitor assumptions.** If something contradicts a stated assumption, stop immediately. Don't try to work around it.

## Replan trigger

When an assumption fails:

1. **Stop.** Don't attempt to fix inline.
2. Commit current state: `c ai-tooling commit --all -m "wip: before replan - <reason>"`
3. Record the learning: `c learning add --assumption "..." --reality "..." --evidence "..." --impact "..."`
4. Create new plan: `c plan "replan-<reason>"`
5. Present new plan for approval before continuing.

## Progress tracking

After completing each task, briefly note what's done. Update `~/work/tickets/<id>/status.md` with current state if the user asks for a status update.

## Decision points

After each task, consider:

- **Going well?** Continue to next task.
- **Hit a snag?** Is it a failed assumption (replan) or just a fixable problem (keep going)?
- **Done?** Check success criteria from the plan. If met, report done.
