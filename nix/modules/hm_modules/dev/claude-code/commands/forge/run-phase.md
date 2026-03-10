---
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(bash:*), Bash(git:*), Bash(ls:*), Bash(find:*), Bash(kubectl:*), Bash(kind:*), Bash(helm:*), Bash(python3:*), AskUserQuestion
description: Run a forge phase test and iterate until passing, fixing obvious bugs automatically and surfacing architectural issues to the user
---

# Forge: Run Phase

Executes a forge phase against local Kind clusters, iterates on failures, and hands off to `update-phase` when the phase passes.

## Subagent Usage

`run-phase` is designed to run as a subagent when orchestrating multiple phases. The iteration loop (run → fail → fix → re-run) consumes significant context; isolating it in a subagent keeps the parent conversation clean.

**When invoked as a subagent:**

- Handle all auto-fixable failures internally without interrupting the parent.
- Do **not** call `AskUserQuestion` — it will route to the calling agent, not the human.
- Instead, collect any blocking issues and include them in the final return message:

  ```
  ## Phase Result: PASS | BLOCKED | FAIL

  ### Summary
  - setup.sh: OK / <error>
  - test.sh: exit 0 / exit N
  - validate.py: N assertions, N failures
  - Auto-fixes applied: N

  ### Blocking Issues (if any)
  <structured failure block from Triage Rules, one per issue>
  ```

- The parent agent is responsible for surfacing blocking issues to the human.

**When invoked directly by the user (the default):** use `AskUserQuestion` as normal.

## Workflow

### 1. Locate the Phase Directory

Determine the ticket ID from the current worktree path or branch name:

```bash
git branch --show-current
# e.g. CLIN-742/init -> ticket is CLIN-742
```

The forge scratch directory is at `~/work/tickets/CLIN-<ticket>/forge/`.

Identify the target phase:

- If an argument was passed (e.g. `/forge:run-phase phase_03`), use that phase directory.
- Otherwise use the highest-numbered `phase_NN/` directory.

Confirm the phase directory exists and contains at minimum `setup.sh` and `test.sh`.

### 2. Enter the Phase Directory

All scripts are run from inside the phase directory so relative paths in the scripts resolve correctly:

```bash
cd ~/work/tickets/CLIN-<ticket>/forge/<phase_NN>
```

### 3. Run setup.sh

```bash
bash setup.sh 2>&1 | tee /tmp/forge-setup.log
```

If `setup.sh` fails:

- Read the log and identify the error.
- Apply the **triage rules** (see below).
- Do NOT proceed to `test.sh` until setup succeeds.

### 4. Run test.sh

```bash
bash test.sh 2>&1 | tee /tmp/forge-test.log
```

Capture full output. Note any non-zero exit code.

### 5. Run validate.py (if present)

```bash
python3 validate.py 2>&1 | tee /tmp/forge-validate.log
```

Parse the output for pass/fail counts, assertion errors, and unexpected responses.

### 6. Evaluate Results

After each run, evaluate all three logs together:

**Pass condition**: `test.sh` exits 0 AND `validate.py` (if present) reports no failures.

If passing: skip to **Step 8**.

If failing: apply the **Triage Rules** below, then loop back to the appropriate step.

---

## Triage Rules

### Fix Automatically (no user confirmation needed)

These are local test scripts on local clusters — fix and re-run immediately:

- **Typo or wrong variable name** in a shell script or Python script
- **Wrong port, wrong hostname, or wrong URL** that doesn't match the forge cluster topology (check `forge.yaml` or `c forge claude-info`)
- **Missing `kubectl wait` or insufficient sleep** causing a race — add or increase the wait
- **Wrong namespace** used in a `kubectl` command
- **Script doesn't handle a resource that doesn't exist yet** — add an existence check or wait loop
- **`validate.py` assertion off-by-one or wrong expected value** when the actual behavior is clearly correct and the expectation is the bug
- **Minor Python syntax error or import missing** in `validate.py`

When auto-fixing: read the relevant script, apply the edit with the Edit tool, briefly state what you changed, and re-run from the appropriate step.

### Surface to User (use AskUserQuestion)

Stop and ask if the failure suggests:

- **The feature under test doesn't work as designed** — the middleware/service behavior is wrong, not the test
- **The forge topology needs to change** — e.g., a different cluster shape, additional components, or a different helm values structure
- **The test is testing the wrong thing** — the phase goal needs revisiting
- **Flaky infrastructure** — consistent unexplained timeouts that aren't a script bug (e.g., cluster DNS not resolving, image pull loops)
- **A bug in the source code** being tested, not in the test itself

When surfacing: present a clear summary:

```
## Failure Requires Your Input

### What Happened
<exact error or assertion failure>

### Why This Isn't a Test Script Bug
<explanation of why the fix isn't obvious or local>

### Options
1. <option 1 — e.g., fix the source code>
2. <option 2 — e.g., adjust the phase scope>
3. <option 3 — e.g., skip this assertion for now>
```

Use AskUserQuestion with those options.

---

### 7. Iteration Cap

After **5 consecutive auto-fix attempts** on the same failure without a passing run, stop and surface the issue to the user regardless of the triage category. Explain what was tried and why it isn't converging.

---

### 8. Phase Passed — Offer Teardown and Documentation

When the phase passes, report a summary:

```
## Phase Passed

- setup.sh: OK
- test.sh: exit 0
- validate.py: N assertions, 0 failures

Iterations: N (N auto-fixes applied)
```

Then ask:

**Question:** "Phase passed. What next?"
**Header:** "Run Phase Complete"
**Options:**

- Label: "Run teardown and update README (Recommended)"
  Description: "Run teardown.sh, then invoke forge:update-phase to document results"
- Label: "Skip teardown, update README"
  Description: "Leave the cluster running, document results now"
- Label: "Skip teardown and README"
  Description: "I'll handle it manually"

If "Run teardown and update README":

```bash
bash teardown.sh 2>&1 | tee /tmp/forge-teardown.log
```

Then invoke the `forge:update-phase` workflow to document results.

If "Skip teardown, update README": invoke `forge:update-phase` directly.

If "Skip teardown and README": acknowledge and exit.
