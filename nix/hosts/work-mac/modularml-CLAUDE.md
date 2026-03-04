# Code Reference Guidelines

When referencing code locations in this repository, always include both the file path and a GitHub permalink for easy navigation.

## GitHub Permalink Format

### For Specific Lines

When referencing specific functions or code sections, include:

- File path with line numbers: `path/to/file.ext:L123-L456`
- GitHub permalink with commit hash: `https://github.com/modularml/mojo/blob/<COMMIT_HASH>/path/to/file.ext#L123-L456`

**Example:**

```text
The `parse_config` function is defined in src/parser/config.py:L45-L78 (https://github.com/modularml/mojo/blob/abc123def456/src/parser/config.py#L45-L78)
```

### For Entire Files

When referencing an entire file:

- File path: `path/to/file.ext`
- GitHub permalink: `https://github.com/modularml/mojo/blob/<COMMIT_HASH>/path/to/file.ext`

**Example:**

```text
The configuration module is in src/parser/config.py (https://github.com/modularml/mojo/blob/abc123def456/src/parser/config.py)
```

### For Directories

When referencing a directory:

- Directory path: `path/to/directory/`
- GitHub permalink: `https://github.com/modularml/mojo/tree/<COMMIT_HASH>/path/to/directory`

**Example:**

```text
Parser implementations are in src/parser/ (https://github.com/modularml/mojo/tree/abc123def456/src/parser)
```

## Important Guidelines

1. **Use commit hashes, not branch names** - This ensures permalinks remain stable even as branches evolve
2. **Get the current commit hash** - Use `git rev-parse HEAD` to get the current commit hash
3. **Include both formats** - Always provide the relative path for local navigation AND the GitHub URL for web access
4. **Line number ranges** - Use `L123-L456` format for multi-line references, `L123` for single lines

## Character Set

**ASCII only in code.** Do not use unicode characters, emojis, or non-ASCII symbols in code, comments, commit messages, or PR descriptions. Stick to the printable ASCII range (0x20-0x7E).

## Repository Information

- **Repository**: <https://github.com/modularml/mojo>
- **To get current commit**: Run `git rev-parse HEAD` in the repository root

## Example Response Format

When answering questions about code locations:

> The error handling logic is implemented in `stdlib/src/error/handler.mojo:L234-L267` (<https://github.com/modularml/mojo/blob/a1b2c3d4e5f6/stdlib/src/error/handler.mojo#L234-L267>)

This format provides:

- Quick local reference: `stdlib/src/error/handler.mojo:L234-L267`
- Stable web link: The full GitHub permalink with commit hash

## Git Worktree Workflow

**CRITICAL**: All work repositories use git worktrees. Each branch lives in its own directory. Always operate within the current worktree root.

### Repository Structure

All repositories use a bare clone in `.bare/` with each branch checked out as a separate worktree directory:

```text
repo/
├── .bare/              # Bare repository (DO NOT use for file operations)
├── .git                # File pointing to .bare
├── main/               # Worktree for default branch
├── feature-name/       # Feature branch worktree
└── TICKET-123/name/    # Work-mode worktree (ticket-namespaced)
```

### Always Use Current Worktree Root

**Find the worktree root**:

```bash
git rev-parse --show-toplevel
# Returns: /path/to/repo/worktree-name
```

**All file operations must use the worktree root as the base path** unless explicitly told otherwise.

### Key Rules

1. **Never use `.bare/` directory** - The bare repository has no working files
2. **Don't confuse sibling worktrees** - Each worktree directory is a different branch
   - ✅ **Correct**: `/path/to/repo/feature-branch/src/main.mojo`
   - ❌ **Wrong**: `/path/to/repo/src/main.mojo` (ambiguous - which worktree?)
3. **The parent directory is not a working tree** - Only individual worktree directories contain files
4. **Always verify you're in the correct worktree** before starting work

### Common Commands

```bash
# List all worktrees
git worktree list

# Create new feature branch worktree
git-wt-feature-branch feature-name

# Create ticket-namespaced worktree (work mode)
git-wt-feature-branch TICKET-123/short-description

# Remove worktree when done
git worktree remove feature-name
```

## Git Commits & Pull Requests

### Commit Message Style

Before creating commits, always check the existing commit style in the repository:

1. **Review recent commits**: Run `git log --oneline -20` to see the last 20 commit messages
2. **Match the existing style**: Observe and replicate:
   - Format conventions (e.g., conventional commits, free-form, etc.)
   - Prefixes or labels (e.g., `[MOJO-123]`, `fix:`, `feat:`, etc.)
   - Capitalization (sentence case vs. lowercase)
   - Verb tense (present vs. past)
   - Length and detail level
3. **Defer to repository conventions**: Do NOT impose a generic commit style. Always follow what the repository already uses.

**Example workflow:**

```bash
# Check recent commits
git log --oneline -20

# Observe patterns like:
# - "[MOJO-456] Add support for async functions"
# - "fix: resolve memory leak in parser"
# - "Update documentation for stdlib module"

# Match the observed style in your commits
```

### Pull Request Templates

Before creating a pull request, check for existing PR templates:

1. **Look for template files**:
   - `.github/PULL_REQUEST_TEMPLATE.md`
   - `.github/pull_request_template.md`
   - `.github/PULL_REQUEST_TEMPLATE/*.md` (multiple templates)

2. **Use the template structure**: If a template exists:
   - Follow the template's section structure exactly
   - Fill in all sections with meaningful content
   - Don't leave placeholder text or empty sections
   - Address all prompts and checklists in the template

3. **If no template exists**: Use a clear, descriptive format:
   - Summary of changes
   - Motivation and context
   - Testing performed
   - Related issues/tickets

**Example:**

```bash
# Check for PR templates
ls -la .github/PULL_REQUEST_TEMPLATE.md
ls -la .github/PULL_REQUEST_TEMPLATE/

# If template exists, structure your PR description to match all sections
```

## AWS Resources

When creating AWS resources manually (via console/clickops):

**Required Tags:**

- `Owner`: Kyle Ondy
- `Managed-By`: Clickops
- `Ticket`: CLIN-nnnn (determine from current work context if possible)

These tags ensure proper resource attribution and tracking.

## Scratch Directory

Use `~/work/tickets/CLIN-<number>/` for temporary files, intermediate artifacts, plans, and anything else that doesn't belong in the source repository.

### Determining the Ticket ID

**From the worktree path** (preferred): The directory name contains the ticket ID.

```
/Users/kondy/src/modularml/mammoth/CLIN-708/shadow-traffic
                                    ^^^^^^^^
                                    CLIN-708
```

**From the git branch name**:

```bash
git branch --show-current
# e.g. CLIN-708/shadow-traffic → ticket is CLIN-708
```

### Creating the Directory

```bash
mkdir -p ~/work/tickets/CLIN-708
```

No required subdirectory conventions — keep it flat or organize however suits the task.

## Investigating Upstream Dependencies

When you need to read or search code in external repositories (upstream libraries, services, dependencies), **clone the repository locally** rather than using `gh api`, `gh` CLI, or web fetching.

### Why Clone Locally?

- Full access to Read, Grep, and Glob tools for effective code search
- No GitHub API rate limits or base64-encoded content to deal with
- Can search across files, trace call chains, and understand structure
- Git history available for `git log`, `git blame`, etc.

### Where to Clone

Clone into the ticket's scratch directory:

```bash
# Structure: ~/work/tickets/CLIN-<number>/repos/<org>/<repo>
mkdir -p ~/work/tickets/CLIN-708/repos/some-org
git clone https://github.com/some-org/some-repo.git ~/work/tickets/CLIN-708/repos/some-org/some-repo
```

### Rules

1. **Always check first** — before cloning, check if the repo already exists in the scratch dir
2. **Use full clones** — do not use `--depth 1`; full history is needed for blame and log
3. **Never clone into the source repository** — upstream code goes in the scratch dir, not the worktree
4. **Clean up is automatic** — repos are scoped to the ticket and removed with it
