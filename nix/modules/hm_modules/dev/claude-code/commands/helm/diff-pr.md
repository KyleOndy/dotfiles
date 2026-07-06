---
allowed-tools: Read, Bash(helm:*), Bash(git:*), Bash(yq:*), Bash(diff:*), Bash(gh:*), Bash(mkdir:*), Bash(mktemp:*), Bash(rm:*), Bash(tar:*), Bash(cat:*), Bash(ls:*), Bash(echo:*), Bash(basename:*), Glob, Grep, AskUserQuestion
argument-hint: <chart-path> <values-file:label> [<values-file:label> ...] [--pr <number>] [--base <branch>]
description: Diff helm template output between base branch and current branch, post result as a PR comment
disable-model-invocation: true
---

# helm:diff-pr

Render `helm template` from both the base branch and current branch, diff the
outputs per environment, and post the result as a collapsible PR comment.

## Arguments

- `<chart-path>` -- relative path to the chart directory (e.g.
  `deployments/helm/hydra-infrastructure`)
- `<values-file:label>` -- one or more pairs of wrapper values file path and a
  display label, colon-separated (e.g.
  `deployments/kubernetes/prod/cluster-config/values.yaml:mammoth-hydra (prod)`)
- `--pr <number>` -- PR number to comment on; defaults to the current branch's
  open PR detected via `gh pr view`
- `--base <branch>` -- base branch to diff against; defaults to `main`

## Workflow

### 1. Parse arguments

Parse `$ARGUMENTS` to extract:

- `chart_path` -- first positional argument
- `envs` -- list of `path:label` pairs (all remaining positional arguments)
- `pr_number` -- value of `--pr` flag, or empty
- `base_branch` -- value of `--base` flag, defaults to `main`

If fewer than two arguments are provided (chart path + at least one env), ask
the user for the missing information via `AskUserQuestion`.

### 2. Derive chart name

```bash
chart_name=$(basename "$chart_path")
```

This is the key used to extract values from wrapper files (e.g.
`hydra-infrastructure`).

### 3. Detect PR number (if not supplied)

```bash
pr_number=$(gh pr view --json number --jq '.number')
```

Fail with a clear message if no open PR is found and `--pr` was not supplied.

### 4. Setup temp directory

```bash
tmpdir=$(mktemp -d)
# subdirs:
#   $tmpdir/base-chart/  -- extracted base branch chart
#   $tmpdir/envs/        -- per-env values and rendered templates
```

### 5. Extract base branch chart

```bash
git archive "$base_branch" -- "$chart_path" | tar -xC "$tmpdir/base-chart/"
```

The resulting chart lives at `$tmpdir/base-chart/$chart_path`.

### 6. Per-environment diff loop

For each `path:label` pair:

a. **Extract sub-key from wrapper values file:**

```bash
yq ".\"$chart_name\"" "$values_path" > "$tmpdir/envs/$safe_label-values.yaml"
```

If the key is missing or the output is `null`, warn the user and skip that
environment.

b. **Render base branch:**

```bash
helm template test "$tmpdir/base-chart/$chart_path" \
  -f "$tmpdir/envs/$safe_label-values.yaml" \
  > "$tmpdir/envs/$safe_label-base.yaml"
```

c. **Render current branch:**

```bash
helm template test "$chart_path" \
  -f "$tmpdir/envs/$safe_label-values.yaml" \
  > "$tmpdir/envs/$safe_label-branch.yaml"
```

d. **Diff:**

```bash
diff "$tmpdir/envs/$safe_label-base.yaml" "$tmpdir/envs/$safe_label-branch.yaml"
```

Capture both output and exit code. Exit code 0 means no diff; exit code 1 means
differences found; any other exit code is an error.

### 7. Format the comment

Build a markdown comment body:

````markdown
## Helm Template Diff: `<chart_name>`

Comparing `<base_branch>` (base) vs current branch for chart `<chart_path>`.

### <label>

<details>
<summary>Diff output (N lines changed / no differences)</summary>

```diff
<diff output here, or "No differences." if clean>
```
````

</details>

---

**Summary:** N environment(s) checked. N changed, N identical.

````

Rules:

- One `<details>` block per environment.
- Summary line in `<summary>` tag: `N lines changed` or `No differences`.
- If there are no diffs across all environments, say so clearly in the summary
  footer.
- Use a `diff` fenced code block so GitHub renders +/- lines in color.

### 8. Post the comment

```bash
gh pr comment "$pr_number" --body "$comment_body"
````

Print the PR URL returned by the command so the user can navigate directly.

### 9. Cleanup

```bash
rm -rf "$tmpdir"
```

## Example Invocation

```
/helm:diff-pr deployments/helm/hydra-infrastructure \
  "deployments/kubernetes/prod/cluster-config/values.yaml:mammoth-hydra (prod)" \
  "deployments/kubernetes/staging/cluster-config/values.yaml:mammoth-hydra-staging (staging)"
```

## Error Handling

- If `helm template` fails for either branch, capture stderr and include it in
  the comment body under the affected environment section so the failure is
  visible in the PR.
- If `git archive` fails (e.g. chart path not on base branch), abort with a
  clear message before posting anything.
- Always run cleanup even on failure.
