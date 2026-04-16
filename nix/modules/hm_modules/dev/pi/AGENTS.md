# Pi Coding Conventions

Global conventions for pi coding agent sessions across all projects.

## Default Workflow

1. **Start with questions** - Clarify scope before acting
2. **Prefer explicit over implicit** - Ask when uncertain
3. **One thing at a time** - Complete before moving on
4. **Checkpoint state** - Update files, status, todo lists

## Communication Style

- **Concise** - Don't over-explain
- **Cited** - Reference file:line for code
- **Honest** - Say when you're unsure
- **Confirm before destructive** - rm, git reset, etc.

## Session Management

Use these commands liberally:

- `/tree` - Navigate session history, branch from old points
- `/fork` - New session from current branch
- `/compact` - When context fills up
- `/name <name>` - Name sessions meaningfully

## File Conventions

### Ticket Work (when in ~/work/tickets/ or ~/tickets/)

Follow the plan-act workflow from the `plan-act` skill:

- `plans/YYYY-MM-DD-HH-MM-meaningful-name.md` - Timestamped plans (many per ticket)
- `todo.md` - Active checklist (rolls across plans)
- `status.md` - Polished updates
- `YYYY-MM-DD-claudes-notes.md` - Detailed working log

### General Projects

- `CLAUDE.md` or `AGENTS.md` - Project-specific conventions
- `TODO.md` - Simple task lists
- `NOTES.md` - Scratchpad for this session

## Tool Preferences

- `read` over `bash cat` (structured output)
- `edit` over `write` for small changes (preserves structure)
- `bash` for: git, grep, find, testing, building

## Git Conventions

- Commit messages: imperative, concise, explain "why" not "what"
- No commits without review unless explicitly told
- Check `git status` before any git operations

## Safety

These require explicit confirmation:

- Deleting files or directories
- Running commands with `sudo` or elevated privileges
- Pushing to remote
- Dropping databases
- Modifying .git/ or sensitive configs

## Mode Philosophy

Pi is unopinionated by design. These are _my_ (the user's) preferences, not inherent constraints:

- I prefer segmented plan/act for complex work
- I want safety rails in research mode
- I like explicit checkpoints
- But pi can do anything I ask it to do

Use `/mode <name>` or `/skill:<name>` to activate specific workflows when helpful.
