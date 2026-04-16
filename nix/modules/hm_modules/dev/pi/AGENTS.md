# Pi Conventions

## Git Identity

Never use `git commit` directly. Always use:

```
c ai-tooling commit -m "message"
c ai-tooling commit --all -m "message"
```

This commits as "Pi Agent" with no GPG signing. The human runs `c claim` later to review and reauthor.

Commit early and often. Small commits with descriptive messages. Never batch unrelated changes.

## Two Workspaces

- **Primary repo** (mammoth, infra, etc.): code changes only
- **~/work/tickets/<ticket-id>/**: everything else (plans, seeds, learnings, notes)

Use `c ai-tooling ticket-id` to detect the current ticket from the branch name.

## Workflow Phases

### 1. Research

Exhaustive upfront investigation. Read files, web search, test hypotheses. No code changes until confident. This phase is allowed to take time and burn tokens. Write findings to the ticket's `notes.md`.

### 2. Plan

Create a timestamped plan: `c plan "plan name"`. Fill in the template, especially the Assumptions section. Stop and get approval before executing.

### 3. Execute

Work from the approved plan. Commit often via `c ai-tooling commit`. When you notice something worth investigating later, plant a seed (see below). Monitor your assumptions. If one breaks, stop and replan.

### 4. Replan (when assumptions fail)

1. **Stop.** Don't fix inline.
2. Commit current state: `c ai-tooling commit --all -m "wip: before replan"`
3. Record the learning: `c learning add --assumption "..." --reality "..." --evidence "..." --impact "..."`
4. Create new plan: `c plan "replan-reason"`
5. Present new plan for approval.

## Crucible Commands

Always prefer these over improvising the operations yourself:

```
c seed plant --title "..." --context "..."    # capture observation
c seed water S001 --context "..."             # add to existing seed
c seed garden                                 # list seeds
c plan "name"                                 # create plan
c learning add --assumption "..." --reality "..."  # record failed assumption
c ticket new CLIN-1050                        # scaffold ticket dir
c ai-tooling commit -m "..."                  # commit with Pi identity
c ai-tooling ticket-id                        # detect ticket from branch
```

## Seeds

When you notice something worth investigating later, plant a seed immediately. This is a quick capture, not a mode switch. Spend ~10 seconds capturing context, call `c seed plant`, and resume what you were doing.

Track seeds you plant during this session. When the user references a seed by description ("that logging seed", "the timeout one"), resolve it to the seed ID and call the appropriate command.

## Communication

- Concise. Don't over-explain.
- Cite code with `file:line` references.
- Be honest about uncertainty.

## Safety

- Confirm before: deleting files, running sudo, pushing to remote, dropping databases.
- Check `git status` before git operations.
- Never modify `.git/` or sensitive configs without asking.
