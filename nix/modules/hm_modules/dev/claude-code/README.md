# Claude Code Home Manager Module

Manages Claude Code configuration declaratively: settings, user memory,
skills, rules, slash commands, an output style, lifecycle and lint hooks, and
a statusline.

## Usage

```nix
hmFoundry.dev.claude-code = {
  enable = true;
};
```

Rebuild with `make deploy-trex` or `make deploy-mac` (this repo embeds
home-manager as a NixOS/darwin module; standalone `home-manager switch` is
not used here). Plain `make deploy` builds `.#$(hostname -s)`, which only
works on a mac whose hostname matches its flake config.

## Options

- **enable**: turn the module on
- **skills** (default `[]`): extra skills as `{ name, source, isFile }`;
  work-mac uses this for vendored third-party skills

Hooks, commands, skills and the user memory file are not switchable. Every
host that enables the module wants all of them, so the toggles were dead
weight.

## What gets installed

- `~/.claude/settings.json`: copied as a real writable file by an
  activation script, not symlinked. Claude Code persists permission
  grants via atomic rename, which fails through a read-only store
  symlink ([#15786](https://github.com/anthropics/claude-code/issues/15786)),
  and the sandbox refuses to start on one
  ([#52525](https://github.com/anthropics/claude-code/issues/52525)).
  Runtime edits survive until the next switch; durable changes belong in
  the repo copy.
- `~/.claude/CLAUDE.md`: user-level memory (kept slim; prose rules live
  in the personal-prose skill)
- `~/.claude/rules/clojure.md`: path-scoped rules, loaded natively by
  Claude Code when matching files are touched
- `~/.claude/statusline.sh`: git branch, model and effort, context, rate
  limits, cost, duration, lines changed
- `~/.claude/hooks/`: hook scripts (below)
- `~/.claude/output-styles/`: the Direct output style
- `~/.claude/skills/`: code-comments, commit-guidelines,
  flake-update-review, grill-me, personal-prose, and the five ponytail
  skills (from the `claude-skills-ponytail` flake input, not this
  directory), plus anything from `cfg.skills`
- `~/.claude/commands/`: the git and code commands (below)

Hook and statusline scripts are packaged with `writeShellApplication`,
so `jq`, `git`, `ffplay`, `tmux`, and GNU `grep` and `sed` come from the
module closure instead of the ambient PATH, and shellcheck runs at build
time.

## Hooks

- **tmux-indicator.sh** (most lifecycle events): sets a per-pane
  `@claude_state` (RUN, EXE, ASK, IDL, ...); `tmux.nix` renders it in
  window titles via its own `tmux-agent-icons.sh`, which reports pi's
  state alongside
- **notification-bell.sh** (Notification): plays `notification.wav`,
  ducks volume during active Zoom calls (macOS)
- **comment-lint.sh** (PostToolUse on Edit, Write, MultiEdit and
  NotebookEdit): flags comments that narrate the edit instead of
  describing the code. It runs after the write lands, so it cannot block;
  exit 2 hands the finding back to the model

Task-completion alerts come from the built-in `preferredNotifChannel`
setting, not a hook. Claude Code sends a desktop notification unprompted
only under Ghostty, Kitty and iTerm2, so alacritty needs the explicit
`terminal_bell` value. tmux swallows the escape sequence without
`allow-passthrough on`, which `tmux.nix` already sets.

## Slash commands

- `/git:history-clean`: rebase and tidy unpushed commits
- `/code:comments`: strip narration and redundancy from comments in the
  working diff

The command directories are real directories with per-file symlinks
(`recursive = true`), so a command under test can be dropped straight
into `~/.claude/commands/<category>/`. Once it earns its keep, move it
into the module.

## Commits

Claude Code commits as the human: nothing sets an agent identity, and
`settings.json` blanks the commit and PR attribution. Launched through
`wtc`, it commits unsigned, and `git adopt` signs the range once it has
been read.

## Troubleshooting

- Run a hook manually with a JSON payload on stdin:

  ```bash
  echo '{"hook_event_name":"Notification","cwd":"'$PWD'"}' | ~/.claude/hooks/notification-bell.sh
  ```

- Harness-level logs: `claude --debug-file /tmp/claude-debug.log`
- Inspect what the module would install:

  ```bash
  DOTFILES_WORKTREE=$(git rev-parse --show-toplevel) nix build --impure \
    .#darwinConfigurations.trex.config.home-manager.users.kyle.home.activationPackage
  ls -la result/home-files/.claude/
  ```

  The pi module reads `DOTFILES_WORKTREE` and throws without it, which is
  why the Makefile targets export it and pass `--impure`. Only trex and
  work-mac enable this module, so building tiger shows nothing.

For general Claude Code support, see the
[official documentation](https://code.claude.com/docs).
