---
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(ls:*), Bash(find:*), Bash(cat:*), AskUserQuestion
description: Analyze completed forge phases and recommend the next phase with rationale and test approach
---

# Forge: Next Phase

Analyzes what the current forge phases have proved, identifies gaps in the feature surface, and recommends a concrete next phase with a rationale and test sketch.

## Workflow

### 1. Locate the Forge Directory

Determine the ticket ID from the current worktree path or branch name:

```bash
git branch --show-current
# e.g. CLIN-742/init -> ticket is CLIN-742
```

The forge scratch directory is at `~/work/tickets/CLIN-<ticket>/forge/`.

Use `ls` to confirm it exists and list its contents:

```bash
ls ~/work/tickets/CLIN-<ticket>/forge/
```

If the forge directory does not exist, report that no forge phases have been set up for this ticket and exit.

### 2. Read the README

Read `~/work/tickets/CLIN-<ticket>/forge/README.md` in full.

Extract:

- **Completed phases**: What each phase set out to prove and what it actually proved
- **"What Was NOT Proved"** sections: Explicit gaps left by each phase
- **"Known Issues"** sections: Bugs or limitations discovered
- **TODO list**: Any forward-looking items the README mentions

### 3. Enumerate Phase Directories

Use `ls` or `find` to list all `phase_NN/` directories under the forge directory. For each phase:

- Note the phase number
- Read `test.sh` and (if present) `validate.py` to understand the current test coverage

Focus on the most recent completed phase's test scripts -- they define the current coverage boundary.

### 4. Read the Middleware Source

Find the recording middleware source in the current worktree:

```bash
git rev-parse --show-toplevel
```

Then search for the middleware implementation:

```bash
grep -r "recording\|middleware\|recorder" --include="*.go" -l <worktree-root>/internal/
```

Read the identified file(s) to understand the full feature surface:

- What configuration options exist
- What behaviors are implemented
- What edge cases the code handles explicitly

Cross-reference against what the existing phase tests exercise to identify untested features.

### 5. Synthesize Recommendations

Based on the README gaps, TODO list, and untested middleware features, identify the top 2-3 candidate next phases ranked by:

1. **Logical progression**: Builds naturally on what the last phase proved
2. **Risk reduction**: Tests behavior that would break silently if wrong
3. **Feature coverage**: Exercises features not yet touched

### 6. Present Recommendation

Output a structured recommendation:

```
## Recommended Next Phase: phase_NN

### Rationale
<Why this is the right next step given what was proved and what wasn't>

### What This Phase Would Prove
- <specific behavior 1>
- <specific behavior 2>
- ...

### What This Phase Would NOT Prove (out of scope)
- <deferred item 1>
- ...

### Test Approach Sketch
<1-3 paragraph description of how to test this: what to deploy, what traffic to send, what to validate>

### Files to Create
- phase_NN/forge.yaml   -- <topology notes, e.g. "copy from phase_MM, same topology">
- phase_NN/setup.sh     -- <what setup does: build, deploy, wait>
- phase_NN/test.sh      -- <what tests do: traffic patterns, commands>
- phase_NN/teardown.sh  -- <cleanup steps>
- phase_NN/validate.py  -- <validation logic: what outputs to check>

---

## Alternative Options

### Option 2: <alternative focus>
<brief rationale and what it would prove>

### Option 3: <another alternative>
<brief rationale and what it would prove>
```

### 7. Confirm with User

Use the AskUserQuestion tool:

**Question:** "Which phase direction should I proceed with?"
**Header:** "Next Phase"
**Options:**

- Label: "Recommended: <phase focus>"
  Description: "<one-line summary of what it proves>"
- Label: "Alternative 2: <focus>"
  Description: "<one-line summary>"
- Label: "Alternative 3: <focus>"
  Description: "<one-line summary>"
- Label: "None of these -- describe what you want"
  Description: "I'll tell you what to focus on instead"

If the user picks "None of these", ask them to describe the focus and use that as the direction. Do not create any files -- just present the recommendation for the user to act on.
