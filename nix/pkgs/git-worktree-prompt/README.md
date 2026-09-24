# git-worktree-prompt

Starship prompt module that shows the git branch, and the worktree it belongs
to in a `.bare`-layout repo. Pure Rust, stdlib only, around 1.9ms per
invocation because it runs on every prompt.

- **Plain repo**, including a `git worktree add` checkout:
  `<branch-icon> <branch>`.
- **`.bare` layout**, with `.bare` at most 4 levels up:
  `<tree-icon> <worktree> → <branch-icon> <branch>`. Just
  `<tree-icon> <worktree>` when the worktree path with `/` turned into `-`
  equals the branch, and `<tree-icon> [bare]` at the root beside `.bare`.
- **Detached HEAD**: the 7-character hash in place of the branch.

The icons default to a tree and U+2387; `GIT_WORKTREE_PROMPT_WORKTREE_ICON`
and `GIT_WORKTREE_PROMPT_BRANCH_ICON` override them.

## Wiring

The overlay in `nix/pkgs/default.nix` exposes `pkgs.git-worktree-prompt`.
`nix/modules/hm_modules/shell/starship.nix` calls it as a custom module and
disables the three built-ins it replaces (`git_branch`, `git_status`,
`git_commit`):

```nix
custom.git-worktree = {
  command = "git-worktree-prompt";
  when = true;
  # Parens make the format conditional: nothing renders outside a repo.
  format = "(on [$output]($style) )";
};
```

The key must be `git-worktree`, matching `"\${custom.git-worktree}"` in the
format string. A hyphen, not an underscore: starship silently renders nothing
if they disagree.

## Building

```bash
nix build .#git-worktree-prompt        # from the repo root, 20-30s
./result/bin/git-worktree-prompt
```

`cargo build` and `cargo test` work from this directory for quick iteration,
but may pick a different toolchain than the Nix build, so confirm with
`nix build` before committing. Tests run as part of the Nix build.

Benchmark:

```bash
nix-shell -p hyperfine --run \
  "hyperfine --warmup 10 --shell=none './result/bin/git-worktree-prompt'"
```

## Debugging

The prompt swallows its own errors so a broken git state cannot break the
shell. To see them:

```bash
git-worktree-prompt --debug
cat "${XDG_STATE_HOME:-$HOME/.local/state}/git-worktree-prompt/error.log"
```

## License

MIT
