# Dotfiles

Nix flake covering five hosts. Per-host detail, where it exists, lives in
`nix/hosts/<host>/`.

## Worktrees

The repo is a bare checkout with one directory per branch beside its
`.bare`: `/Users/kyle/src/dotfiles/` on trex, `/Users/kondy/src/kyleondy/dotfiles/`
on work-mac. Resolve every path from the worktree root, not from that parent:

```bash
git rev-parse --show-toplevel   # trex: /Users/kyle/src/dotfiles/main
```

The flake reads the git tree, so a new file is invisible to `nix eval` and
`nix build` until it is `git add`ed.

Build and deploy through `make`. It exports `DOTFILES_WORKTREE` and passes
`--impure`, and without both, pi-coding-agent's `sourceDir` throws on every
host that enables it (all but pika and cogsworth).

Verify with the command in `.pi/verify.json`. Not `nix flake check`, which
also evaluates the Linux hosts and cannot go green on a mac.

## Hosts

| Host        | Platform       | Role                    | Deploy                                                  |
| ----------- | -------------- | ----------------------- | ------------------------------------------------------- |
| `tiger`     | x86_64-linux   | homelab server          | `make deploy-rs HOSTNAME=tiger`                         |
| `pika`      | x86_64-linux   | ODROID-H2, second copy  | deploy-rs, or `make iso-pika` for a fresh install       |
| `cogsworth` | aarch64-linux  | Raspberry Pi 5 kiosk    | deploy-rs, or `make sdcard-cogsworth` for a fresh image |
| `trex`      | aarch64-darwin | personal mac            | `make deploy-trex`                                      |
| `work-mac`  | aarch64-darwin | work mac (user `kondy`) | `make deploy-mac`                                       |

`make deploy-rs HOSTNAME=<host>` lets deploy-rs run its own `nix flake check`
first, which fetches the private cogsworth input, so it needs that ssh key.
`make deploy-rs-all-dry` runs `nix flake check`, then dry-activates tiger,
pika and cogsworth. `make help` lists only the targets marked `##`, which
leaves out the `deploy-rs*` ones.

pika holds tier 2 of `docs/backup-strategy.md` and opens every connection
itself: tiger holds no credential for it and cannot initiate anything toward
it.

## Secrets

sops files: `nix/secrets/<host>.yaml` per host, plus `shared-<hosts>.yaml`
for a secret several hosts need, so no host can decrypt another's.
`.sops.yaml` holds the recipients. The berkeley-mono and pragmata-pro fonts
and the `tf/` state are git-crypt encrypted. The key lives per worktree
(`.bare/worktrees/<name>/git-crypt/keys/`) and the filter is marked required,
so every `git worktree add` fails until the key is copied into the new
worktree's git dir.

The `secrets-check` hook runs on commit and on push and reads the bytes git
stores, so a decrypted worktree file never counts as plaintext.
