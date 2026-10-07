# git-worktree-prompt

Starship prompt module that shows the git branch, and the worktree it belongs
to in a `.bare`-layout repo. Pure Rust, stdlib only, around 1.9ms per
invocation because it runs on every prompt.

- **Plain repo**, including a `git worktree add` checkout:
  `<branch-icon> <branch>`.
- **`.bare` layout**, any worktree inside the directory that holds the
  `.bare` it shares: `<tree-icon> <worktree> → <branch-icon> <branch>`. Just
  `<tree-icon> <worktree>` when the worktree path, as is or with `/` turned
  into `-`, equals the branch, and `<tree-icon> [bare]` at the root beside
  `.bare`. A clone or submodule nested inside a worktree, and a worktree
  added outside that directory, are plain repos.
- **Detached HEAD**: the 7-character hash in place of the branch.
- **reftable repo**: HEAD holds a fixed stub there, so it asks git, at the
  cost of one process.

The icons default to a tree and U+2387; `GIT_WORKTREE_PROMPT_WORKTREE_ICON`
and `GIT_WORKTREE_PROMPT_BRANCH_ICON` override them.

## Wiring

The overlay in `nix/pkgs/default.nix` exposes `pkgs.git-worktree-prompt`.
`nix/modules/hm_modules/shell/starship.nix` calls it as a custom module and
disables the three built-ins it replaces (`git_branch`, `git_status`,
`git_commit`):

```nix
custom.git-worktree = {
  shell = [ "git-worktree-prompt" ];
  command = "";
  use_stdin = false;
  require_repo = true;
  when = true;
  # Parens make the format conditional: nothing renders outside a repo.
  format = "(on [$output]($style) )";
};
```

Naming the binary as `shell` with `use_stdin = false` runs it directly.
Without that, starship starts zsh and pipes the command into it, which costs
more than the binary itself.

The key must be `git-worktree`, matching `"\${custom.git-worktree}"` in the
format string. A hyphen, not an underscore: starship silently renders nothing
if they disagree.

## Building

```bash
nix build .#darwinConfigurations.trex.pkgs.git-worktree-prompt  # from the repo root, 20-30s
./result/bin/git-worktree-prompt
```

`cargo build` and `cargo test` work from this directory for quick iteration,
but may pick a different toolchain than the Nix build, so confirm with
`nix build` before committing. Tests run as part of the Nix build and need
`git` 2.45 or later for the reftable case.

Benchmark:

```bash
nix-shell -p hyperfine --run \
  "hyperfine --warmup 10 --shell=none './result/bin/git-worktree-prompt'"
```

## Debugging

The prompt swallows its own errors so a broken git state cannot break the
shell. To see one, run it by hand in the directory where the prompt looks
wrong:

```bash
git-worktree-prompt --debug
```

## License

MIT
