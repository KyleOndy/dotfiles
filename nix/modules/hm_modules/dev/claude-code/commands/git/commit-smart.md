---
allowed-tools: Bash(git:*), Read, LS, AskUserQuestion
argument-hint: [--preview] [--split]
description: Create contextual commits based on chat history and current changes
---

# Smart Contextual Commit

**Skill Level:** Intermediate  
**Risk Level:** Low (creates commits, can be undone)

Creates meaningful commit messages by analyzing both the current chat conversation and file changes to capture the intent behind the work, not just the technical changes.

## Features

- **Intelligent Staging**: Uses staged changes if present, otherwise stages all unstaged changes
- **Chat Context Analysis**: Extracts the "why" from conversation history
- **File Change Categorization**: Understands different types of changes (features, fixes, docs)
- **Conventional Commits**: Generates properly formatted commit messages
- **Preview Mode**: Review proposed commit message before committing

## Workflow

### 1. Change Detection and Staging

**Check current state:**

Use the Bash tool to run these commands:

1. Run `git status --porcelain` to check current state
2. Run `git diff --cached --name-only` to get staged files
3. Run `git diff --name-only` to get unstaged files

**Determine staging strategy:**

- If there are staged files: Use those for the commit and proceed
- If no changes at all: Report "No changes to commit" and exit
- If no staged files but there are unstaged files: Prompt user for staging decision

**If unstaged files exist:**

Use the AskUserQuestion tool:

**Question:** "No files are staged. How would you like to proceed?"
**Header:** "Staging"
**Options:**

- Label: "Stage all changes (Recommended)"
  Description: "Stage all unstaged files and create one commit"
- Label: "Stage selectively"
  Description: "I'll use git add to stage specific files first"
- Label: "Cancel"
  Description: "Exit without committing"

**Handle responses:**

- "Stage all changes" → Run `git add -A` and continue with commit
- "Stage selectively" → Exit with message to run `git add` first
- "Cancel" → Exit without taking action

**Report summary:**

```text
📊 Change Summary:
  Staged files: [count]
  Unstaged files: [count]

[Status message: "✅ Using staged changes only" or "📦 Staging all unstaged changes"]

Files to commit:
  - [list each file]
```

### 2. Chat Context Analysis

Based on the current conversation, identify:

- **Primary Goal**: What was the main objective or user request?
- **Key Accomplishments**: What specific features, fixes, or improvements were made?
- **Technical Decisions**: Any important architectural or implementation choices
- **Problem Solving**: What challenges were overcome during implementation?

**Chat Summary**: [Analyze the conversation and summarize the key context here]

### 3. File Change Analysis

**Get files to be committed:**

Run `git diff --cached --name-only` to get the list of staged files.

**Categorize by file type:**

Analyze the file extensions to identify:

- **Code files**: `.js`, `.jsx`, `.ts`, `.tsx`, `.py`, `.go`, `.rs`, `.java`, `.cpp`, `.c`, `.clj`, `.cljs`, `.cljc`, `.nix`
- **Config files**: `.json`, `.yaml`, `.yml`, `.toml`, `.ini`, `.conf`, `.env`, `package.json`, `Cargo.toml`, `deps.edn`
- **Documentation**: `.md`, `.rst`, `.txt`, `README`
- **Tests**: Files containing `test` or `spec` in their path

**Categorize by change type:**

Use these git commands:

- `git diff --cached --name-only --diff-filter=A` for new files (Added)
- `git diff --cached --name-only --diff-filter=M` for modified files (Modified)
- `git diff --cached --name-only --diff-filter=D` for deleted files (Deleted)

**Report the analysis:**

```text
📁 File Analysis:
  Code files: [count]
  Config files: [count]
  Documentation: [count]
  Tests: [count]

📝 Change Types:
  New: [count] files
  Modified: [count] files
  Deleted: [count] files
```

### 4. Commit Message Generation

Based on the chat context and file analysis, generate a commit message following conventional commit format.

**Determine commit type:**

Use this priority order to select the appropriate type:

1. If there are new code files (`.js`, `.jsx`, `.ts`, `.tsx`, `.py`, `.go`, `.rs`, `.java`, `.cpp`, `.c`, `.clj`, `.nix`) → `feat`
2. If only test files changed (`test` or `spec` in path) → `test`
3. If only documentation files changed (`.md`, `.rst`, `.txt`) → `docs`
4. If only config files changed (`.json`, `.yaml`, `.yml`, `.toml`, etc.) → `chore`
5. If single code file changed (likely a bug fix) → `fix`
6. Default → `feat`

**Determine scope (optional):**

Look at the directories containing changed files:

- If directories contain `auth` → scope: `auth`
- If directories contain `api` → scope: `api`
- If directories contain `ui` or `components` → scope: `ui`
- If directories contain `test` → scope: `test`
- If directories contain `docs` → scope: `docs`
- If directories contain `infra` or `infrastructure` → scope: `infra`
- If directories contain `nix` or Nix module paths → scope: appropriate Nix scope (e.g., `nix`, `home-manager`, `hosts`)
- Otherwise → use the most common directory name as scope

**Generate description:**

Based on the commit type and chat context analysis:

- **feat**: `add [concise description of new feature/capability]`
- **fix**: `resolve [issue description]` or `correct [problem description]`
- **docs**: `update [what documentation]` or `add [documentation topic]`
- **test**: `add tests for [feature]` or `improve test coverage for [area]`
- **chore**: `update [tool/dependency/config]`
- **refactor**: `restructure [component/module]`

The description should:

- Be derived from the chat context analysis (Section 2)
- Be concise and specific
- Use imperative mood (add, fix, update, not added, fixed, updated)
- Focus on WHAT and WHY, not HOW

**Build the final commit message:**

Format: `<type>(<scope>): <description>`

If no scope is applicable, use: `<type>: <description>`

**Report the proposed message:**

```text
💬 Proposed commit message:
  [type]([scope]): [description]
```

### 5. Commit Creation

**Show final summary:**

Display a review of what will be committed:

```text
🔍 Final Review:
  Type: [commit_type]
  Scope: [scope] (if applicable)
  Files: [count]
  Message: [full_commit_message]
```

**Check for preview mode:**

If the command was invoked with `--preview` flag:

- Display: `👁️  Preview mode - not committing`
- Display: `To commit, run the command without --preview`
- Exit without creating the commit

**Confirm commit creation:**

If not in preview mode, ask for user confirmation before committing:

Use the AskUserQuestion tool:

**Question:** "Ready to create this commit?"
**Header:** "Commit"
**Options:**

- Label: "Yes, commit now (Recommended)"
  Description: "Create the commit with the proposed message"
- Label: "Edit message first"
  Description: "I want to modify the commit message"
- Label: "Cancel"
  Description: "Don't create the commit"

**Handle responses:**

- "Yes, commit now" → Proceed with creating the commit
- "Edit message first" → Ask user for their preferred message, then commit with their message
- "Cancel" → Exit without creating commit

**Create the commit:**

After user confirms, create the commit using:

```bash
git commit -m "[commit_message]"
```

For multi-line commit messages (if body is needed), use a heredoc:

```bash
git commit -m "$(cat <<'EOF'
[type]([scope]): [description]

[optional body explaining the change]

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

**Verify the commit:**

After successful commit:

- Display: `✅ Commit created successfully!`
- Run `git log -1 --oneline` to show the commit
- Display the commit summary:

```text
📋 Summary:
[hash] [commit message]
```

If the commit fails:

- Display: `❌ Commit failed`
- Show the error message from git
- Exit with error status

## Usage Examples

### Basic Usage

```bash
# Make changes, then run the command
/commit-context
```

### Preview Mode

```bash
# See proposed commit message without committing
/commit-context --preview
```

### With Staged Changes

```bash
# Stage specific files, then commit with context
git add src/auth.js src/login.jsx
/commit-context
```

## Tips

1. **Be Descriptive in Chat**: The more context you provide in conversation, the better the commit message
2. **Stage Selectively**: Use `git add` to stage only related changes for focused commits
3. **Use Preview**: Always preview complex commits before creating them
4. **Chat Context Matters**: Mention the specific feature, bug, or improvement you're working on

## Expected Commit Message Formats

- `feat: add user authentication system`
- `fix: resolve login validation issue`
- `feat(auth): implement password reset functionality`
- `docs: update API documentation with examples`
- `test: add unit tests for user service`
- `refactor(ui): extract reusable button component`
