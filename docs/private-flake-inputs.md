# Private flake inputs over SSH

The flake pulls some inputs over `git+ssh://` (e.g. `cogsworth`). On
hosts where the default SSH identity isn't the personal GitHub
account — typical for work machines where the agent holds the work
key — Nix will auth with the wrong identity and GitHub returns
`Repository not found` for private repos.

The `Makefile` lifts this repo's `core.sshCommand` into
`GIT_SSH_COMMAND` and preserves it through `sudo`, so the same key
used for `git fetch` in this worktree is used by Nix's fetcher. That
takes care of routing — but ssh still tries agent keys before the
explicit `-i` key, so a wrong-identity agent key can still win.

Add `IdentitiesOnly=yes` to the repo's `core.sshCommand` so ssh only
uses the explicit key:

```bash
git config core.sshCommand "ssh -i ~/.ssh/personal -o IdentitiesOnly=yes"
```

After this:

- `git fetch` / `git push` in this repo use `~/.ssh/personal`, agent ignored.
- `make deploy` lifts the same command into `GIT_SSH_COMMAND`, Nix's
  fetcher uses it, agent ignored.

## Skipping the passphrase prompt

Bypassing the agent means ssh prompts for the key passphrase each
fetch. On macOS, store it in the keychain once:

```bash
ssh-add --apple-use-keychain ~/.ssh/personal
```

And add to `~/.ssh/config`:

```
Host github.com
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/personal
```

## Debugging

If a deploy fails with `Repository not found`, add `-v` to see which
identity ssh actually offered:

```bash
GIT_SSH_COMMAND="ssh -i $HOME/.ssh/personal -v" \
  sudo --preserve-env=GIT_SSH_COMMAND \
  nix flake metadata --refresh "git+ssh://git@github.com/<owner>/<repo>"
```

Look for `Offering public key:` and `Server accepts key:` — if the
fingerprint isn't your personal key, ssh is reaching past `-i` to the
agent. Fix with `IdentitiesOnly=yes` as above.
