---
allowed-tools: Bash(git:*), Read, LS
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

Use `git status --porcelain` to check the current state, then run the following bash script:

```bash
# Detect current state
STAGED_FILES=$(git diff --cached --name-only)
UNSTAGED_FILES=$(git diff --name-only)
STAGED_COUNT=$(echo "$STAGED_FILES" | grep -c . || echo 0)
UNSTAGED_COUNT=$(echo "$UNSTAGED_FILES" | grep -c . || echo 0)

echo "📊 Change Summary:"
echo "  Staged files: $STAGED_COUNT"
echo "  Unstaged files: $UNSTAGED_COUNT"

# Determine staging strategy
if [ $STAGED_COUNT -gt 0 ]; then
  echo "✅ Using staged changes only"
  FILES_TO_COMMIT="$STAGED_FILES"
elif [ $UNSTAGED_COUNT -gt 0 ]; then
  echo "📦 Staging all unstaged changes"
  git add .
  FILES_TO_COMMIT="$UNSTAGED_FILES"
else
  echo "❌ No changes to commit"
  exit 0
fi

echo "Files to commit:"
echo "$FILES_TO_COMMIT" | sed 's/^/  - /'
```

### 2. Chat Context Analysis

Based on the current conversation, identify:

- **Primary Goal**: What was the main objective or user request?
- **Key Accomplishments**: What specific features, fixes, or improvements were made?
- **Technical Decisions**: Any important architectural or implementation choices
- **Problem Solving**: What challenges were overcome during implementation?

**Chat Summary**: [Analyze the conversation and summarize the key context here]

### 3. File Change Analysis

```bash
# Get files to be committed (staged files)
COMMIT_FILES=$(git diff --cached --name-only)

# Categorize by file type
CODE_FILES=$(echo "$COMMIT_FILES" | grep -E '\.(js|jsx|ts|tsx|py|go|rs|java|cpp|c|clj|cljs|cljc)$' || true)
CONFIG_FILES=$(echo "$COMMIT_FILES" | grep -E '\.(json|yaml|yml|toml|ini|conf|env)$|package\.json|Cargo\.toml|deps\.edn' || true)
DOC_FILES=$(echo "$COMMIT_FILES" | grep -E '\.(md|rst|txt)$|README' || true)
TEST_FILES=$(echo "$COMMIT_FILES" | grep -E 'test|spec' || true)

# Categorize by change type
NEW_FILES=$(git diff --cached --name-only --diff-filter=A)
MODIFIED_FILES=$(git diff --cached --name-only --diff-filter=M)
DELETED_FILES=$(git diff --cached --name-only --diff-filter=D)

echo "📁 File Analysis:"
[ -n "$CODE_FILES" ] && echo "  Code files: $(echo "$CODE_FILES" | wc -l)"
[ -n "$CONFIG_FILES" ] && echo "  Config files: $(echo "$CONFIG_FILES" | wc -l)"
[ -n "$DOC_FILES" ] && echo "  Documentation: $(echo "$DOC_FILES" | wc -l)"
[ -n "$TEST_FILES" ] && echo "  Tests: $(echo "$TEST_FILES" | wc -l)"

echo "📝 Change Types:"
[ -n "$NEW_FILES" ] && echo "  New: $(echo "$NEW_FILES" | wc -l) files"
[ -n "$MODIFIED_FILES" ] && echo "  Modified: $(echo "$MODIFIED_FILES" | wc -l) files"
[ -n "$DELETED_FILES" ] && echo "  Deleted: $(echo "$DELETED_FILES" | wc -l) files"
```

### 4. Commit Message Generation

Based on the chat context and file analysis, generate a commit message following conventional commit format:

```bash
# Determine commit type based on changes and context
determine_commit_type() {
  # Priority order for commit type detection

  if [ -n "$NEW_FILES" ] && echo "$NEW_FILES" | grep -qE '\.(js|jsx|ts|tsx|py|go|rs|java|cpp|c|clj)$'; then
    echo "feat"
  elif echo "$COMMIT_FILES" | grep -qE 'test|spec'; then
    echo "test"
  elif [ -n "$DOC_FILES" ]; then
    echo "docs"
  elif echo "$COMMIT_FILES" | grep -qE '\.(json|yaml|yml|toml|package\.json|Cargo\.toml)$'; then
    echo "chore"
  elif [ $(echo "$COMMIT_FILES" | wc -l) -eq 1 ] && echo "$COMMIT_FILES" | head -1 | grep -qE '\.(js|jsx|ts|tsx|py|go|rs)$'; then
    # Single file change - likely a fix
    echo "fix"
  else
    echo "feat"
  fi
}

# Detect scope from file paths
determine_scope() {
  # Look for common directory patterns
  DIRS=$(echo "$COMMIT_FILES" | xargs dirname | sort | uniq)

  # Check for specific patterns
  if echo "$DIRS" | grep -q "auth"; then
    echo "auth"
  elif echo "$DIRS" | grep -q "api"; then
    echo "api"
  elif echo "$DIRS" | grep -q "ui\|components"; then
    echo "ui"
  elif echo "$DIRS" | grep -q "test"; then
    echo "test"
  elif echo "$DIRS" | grep -q "docs"; then
    echo "docs"
  else
    # Use the most common directory
    echo "$DIRS" | head -1 | xargs basename
  fi
}

COMMIT_TYPE=$(determine_commit_type)
SCOPE=$(determine_scope)

# Generate description based on chat context and changes
generate_description() {
  # This should be filled in based on the chat analysis above
  # For now, provide a template that the user will customize

  case $COMMIT_TYPE in
    "feat")
      echo "add [description based on chat context]"
      ;;
    "fix")
      echo "resolve [issue description from chat]"
      ;;
    "docs")
      echo "update documentation"
      ;;
    "test")
      echo "add tests for [feature from chat]"
      ;;
    "chore")
      echo "update configuration"
      ;;
    *)
      echo "[description from chat context]"
      ;;
  esac
}

DESCRIPTION=$(generate_description)

# Build final commit message
if [ -n "$SCOPE" ] && [ "$SCOPE" != "." ]; then
  COMMIT_MESSAGE="$COMMIT_TYPE($SCOPE): $DESCRIPTION"
else
  COMMIT_MESSAGE="$COMMIT_TYPE: $DESCRIPTION"
fi

echo "💬 Proposed commit message:"
echo "  $COMMIT_MESSAGE"
```

### 5. Commit Creation

```bash
# Show final summary
echo ""
echo "🔍 Final Review:"
echo "  Type: $COMMIT_TYPE"
[ -n "$SCOPE" ] && [ "$SCOPE" != "." ] && echo "  Scope: $SCOPE"
echo "  Files: $(echo "$COMMIT_FILES" | wc -l)"
echo "  Message: $COMMIT_MESSAGE"

# Check for preview mode
if [[ "$1" == "--preview" ]]; then
  echo ""
  echo "👁️  Preview mode - not committing"
  echo "To commit, run the command without --preview"
  exit 0
fi

# Create the commit
echo ""
echo "✨ Creating commit..."
git commit -m "$COMMIT_MESSAGE"

if [ $? -eq 0 ]; then
  echo "✅ Commit created successfully!"
  echo ""
  echo "📋 Summary:"
  git log -1 --oneline
else
  echo "❌ Commit failed"
  exit 1
fi
```

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
