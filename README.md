# dotfiles

Nix flake defining four machines end to end: two NixOS hosts, two Macs via
nix-darwin, all user config through home-manager. Personal repo, not a
reference architecture.

## Hosts

| Host        | Platform       | Role                    | Profile   | Deploy             |
| ----------- | -------------- | ----------------------- | --------- | ------------------ |
| `tiger`     | x86_64-linux   | homelab server          | `desktop` | deploy-rs          |
| `cogsworth` | aarch64-linux  | Raspberry Pi 5 kiosk    | `kiosk`   | deploy-rs          |
| `trex`      | aarch64-darwin | personal mac            | `desktop` | `make deploy-trex` |
| `work-mac`  | aarch64-darwin | work mac (user `kondy`) | `desktop` | `make deploy-mac`  |

Profiles live in `nix/profiles/`: `desktop.nix` and `kiosk.nix`, both built
from the pieces in `nix/profiles/common/`. There is no separate server
profile; tiger runs the desktop profile because it has a monitor attached.

## Layout

```text
nix/
├── hosts/          per-host configuration.nix + hardware-configuration.nix
├── modules/
│   ├── hm_modules/   home-manager modules, namespaced hmFoundry
│   └── nix_modules/  NixOS modules, namespaced systemFoundry
├── pkgs/           locally defined packages and overlays
├── profiles/       desktop and kiosk, plus the common/ pieces
├── nixcats/        neovim config as a nixCats package
├── checks/         flake checks
└── secrets/        sops-encrypted secrets
docs/  keyboard/  tf/  util/  fuji-recipes/
```

Every `.nix` under `nix/modules/` is imported automatically, so a helper file
that is not a module will break evaluation.

## Commands

```bash
make help              # everything else
make build             # build the current host
make deploy            # switch the current host
make deploy-rs-all-dry # dry-run tiger and cogsworth
make update            # update flake inputs
make check             # flake checks
make cleanup           # collect garbage, optimise the store
```

## Work config

`work-mac` pulls employer-specific config from a `work-config` flake input,
which defaults to the empty stub at `nix/work-config-stub/`. Point it at the
real thing to build with it, and nothing work-specific ever lands in this
repo:

```bash
make build-mac WORK_CONFIG=/Users/kondy/work
```

The Makefile turns that into `--override-input work-config path:$WORK_CONFIG`.

## Secrets

sops-nix, keyed to age. Encrypted values live in `nix/secrets/secrets.yaml`;
the berkeley-mono fonts under `nix/pkgs/` are git-crypt encrypted separately,
which is why a clone without the key cannot evaluate the flake.

## Non-goals

Reusability, stability, and being a good example. This is optimised for one
person's workflow, `main` breaks when I am experimenting, and the modules
assume my specific hosts.

## Reference

- [terlar/nix-config](https://github.com/terlar/nix-config)
- [utdemir/dotfiles](https://github.com/utdemir/dotfiles)
- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)
