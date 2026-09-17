# Claude Code Home Manager Module

Manages Claude Code configuration declaratively: settings, user memory,
skills, rules, slash commands, notification hooks, and a statusline.

## Usage

```nix
hmFoundry.dev.claude-code = {
  enable = true;
};
```

Rebuild with `make deploy` (this repo embeds home-manager as a
NixOS/darwin module; standalone `home-manager switch` is not used here).

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
- `~/.claude/statusline.sh`: git branch, model, context usage, rate
  limits, cost, duration
- `~/.claude/hooks/`: hook scripts (below)
- `~/.claude/skills/`: commit-guidelines, flake-update-review, grill-me,
  personal-prose, and the ponytail family (those last five from the
  `claude-skills-ponytail` flake input, not this directory), plus
  anything from `cfg.skills`
- `~/.claude/commands/`: the task family and git commands (below)

Hook and statusline scripts are packaged with `writeShellApplication`,
so `jq`, `ffplay`, `tmux`, and GNU `date` come from the module closure
instead of the ambient PATH, and shellcheck runs at build time.

## Hooks

- **tmux-indicator.sh** (most lifecycle events): sets a per-pane
  `@claude_state` (RUN, EXE, ASK, IDL, ...); `tmux.nix` renders it in
  window titles via its own `tmux-agent-icons.sh`, which reports pi's
  state alongside
- **notification-bell.sh** (Notification): plays `notification.wav`,
  ducks volume during active Zoom calls (macOS)

Task-completion alerts come from the built-in `preferredNotifChannel`
setting, not a hook. Claude Code sends a desktop notification unprompted
only under Ghostty, Kitty and iTerm2, so alacritty needs the explicit
`terminal_bell` value. tmux swallows the escape sequence without
`allow-passthrough on`, which `tmux.nix` already sets.

## Slash commands

- `/git:history-clean`: rebase and tidy unpushed commits

The command directories are real directories with per-file symlinks
(`recursive = true`), so a command under test can be dropped straight
into `~/.claude/commands/<category>/`. Once it earns its keep, move it
into the module.

## Troubleshooting

- Run a hook manually with a JSON payload on stdin:

  ```bash
  echo '{"hook_event_name":"Notification","cwd":"'$PWD'"}' | ~/.claude/hooks/notification-bell.sh
  ```

- Harness-level logs: `claude --debug-file /tmp/claude-debug.log`
- Inspect what the module would install:

  ```bash
  nix build .#darwinConfigurations.trex.config.home-manager.users.kyle.home.activationPackage
  ls -la result/home-files/.claude/
  ```

  Only trex and work-mac enable this module, so building tiger shows
  nothing.

For general Claude Code support, see the
[official documentation](https://code.claude.com/docs).
