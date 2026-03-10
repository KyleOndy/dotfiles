---
allowed-tools: Read, Grep, Glob, Bash(gh:*), Bash(git:*), Bash(ls:*), Bash(find:*), AskUserQuestion, mcp__claude_ai_Linear__list_issues, mcp__claude_ai_Linear__get_issue, mcp__claude_ai_Linear__list_comments, mcp__claude_ai_Linear__save_comment, mcp__claude_ai_Linear__get_user
description: Post status updates to Linear tickets from local context
---

Post a status update to one or more Linear tickets. Gathers context from local branches,
GitHub PRs, and scratch directories, then drafts an update for your review before posting.

## Update Format

```
## Status Update

[1-3 sentence summary of current state]

**Done since last update:**
- [concrete items with PR/branch links where relevant]

**Next:**
- [planned work items]

**Open questions:**
- [decisions needed, things to discuss, uncertainties]

**Blockers:** None
```

Omit empty sections. Include "Open questions" only when there are genuine decisions or
uncertainties that benefit from team input. Include "Blockers" only when there are actual
blockers.

## Workflow

### Step 1: Identify tickets to update

Use `mcp__claude_ai_Linear__get_user` with `"me"` to get the current user, then use
`mcp__claude_ai_Linear__list_issues` filtered to issues assigned to me that are not
completed or cancelled.

Group tickets by status. Present all "In Progress" tickets as pre-selected candidates,
using the format `CLIN-XXX [Title]` for each.

Use AskUserQuestion to confirm the list:

- Show all "In Progress" tickets as the default selection
- Ask if the user wants to add any non-In-Progress tickets (list them)
- Ask if the user wants to skip any In Progress tickets

### Step 2: Gather context per ticket

For each selected ticket, run these steps in order:

**a) Last status update**

Use `mcp__claude_ai_Linear__list_comments` on the issue. Find the most recent comment
containing "## Status Update". Note its date -- all new activity should be framed as
"since that date". If no prior status update exists, gather all available context.

**b) GitHub PRs**

Search for PRs referencing the ticket number:

```bash
gh pr list --search "CLIN-XXX" --state all --json number,title,state,url,mergedAt,updatedAt
```

Run this across relevant repos (mammoth, any others visible in the worktree path).
Focus on PRs opened, merged, or updated since the last status update.

**c) Local branches**

Search for branches matching the ticket number across mammoth repos:

```bash
git -C /Users/kondy/src/modularml/mammoth -C <worktree> branch --list "*CLIN-XXX*" 2>/dev/null
```

For any branches found, get the recent commit log since the last update:

```bash
git -C <repo> log --oneline --since="<last-update-date>" <branch>
```

**d) Scratch directory**

Check `~/work/tickets/CLIN-XXX/` for existence. If it exists:

- List contents to understand what's there
- Read `README.md` if present
- Look for forge configs, test result files, plans
- Note phases that exist and their apparent state (setup scripts, test scripts, recordings)

**e) Synthesize**

Compare what exists now vs. what the last status update described. Identify:

- New PRs opened or merged
- New commits on local branches
- New test phases or forge configs
- New scratch dir content (plans, results, notes)

Draft the update focusing on the delta since the last update.

### Step 3: Flag concerns

Before presenting the draft, if you notice any of the following, raise them as explicit
questions in the AskUserQuestion prompt for that ticket:

- The ticket has been "In Progress" but there's no activity since the last update
- PRs with open review comments that haven't been addressed
- Scratch dir exists but shows no recent changes
- Local branches with no recent commits
- Anything else that looks like it might be a stale or blocked ticket

### Step 4: Review each draft

Present each draft one at a time using AskUserQuestion:

```
Review update for CLIN-XXX: [Title]

---
[draft text here]
---

[any concerns flagged in Step 3]

Options: Approve / Edit / Skip
```

If the user chooses Edit, ask what to change, regenerate the draft, and present it again.
Collect all approved updates before posting.

### Step 5: Post approved updates

For each approved update, use `mcp__claude_ai_Linear__save_comment` to post the comment
on the issue. After all updates are posted, report success with the issue identifiers.
