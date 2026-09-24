# dotfiles

Nix flake defining five machines end to end: three NixOS hosts, two Macs via
nix-darwin, all user config through home-manager. Personal repo, not a
reference architecture.

## Hosts

| Host        | Platform       | Role                    | Profile     | Deploy             |
| ----------- | -------------- | ----------------------- | ----------- | ------------------ |
| `tiger`     | x86_64-linux   | homelab server          | `server`    | deploy-rs          |
| `pika`      | x86_64-linux   | backup host (ODROID-H2) | `appliance` | deploy-rs          |
| `cogsworth` | aarch64-linux  | Raspberry Pi 5 kiosk    | `kiosk`     | deploy-rs          |
| `trex`      | aarch64-darwin | personal mac            | `desktop`   | `make deploy-trex` |
| `work-mac`  | aarch64-darwin | work mac (user `kondy`) | `desktop`   | `make deploy-mac`  |

Profiles live in `nix/profiles/`, built from the pieces in
`nix/profiles/common/`:

- **`server.nix`**: the full dev environment with no GUI (tiger).
- **`desktop.nix`**: `server.nix` plus the GUI layer (the Macs).
- **`kiosk.nix`**: just enough for a single-purpose display (cogsworth).
- **`appliance.nix`**: headless and data-holding, no dev tools (pika).

## Layout

```text
nix/
├── hosts/          configuration.nix, plus hardware-configuration.nix (NixOS)
│                   or home.nix (Macs)
├── lib/            shared values (kyle's authorized keys)
├── modules/
│   ├── hm_modules/     home-manager modules, namespaced hmFoundry
│   ├── nix_modules/    NixOS modules, namespaced systemFoundry
│   └── darwin_modules/ nix-darwin modules
├── pkgs/           locally defined packages and overlays
├── profiles/       server, desktop, kiosk and appliance, plus common/
├── work-config-stub/ the empty default for the work-config input
├── nixcats/        neovim config as a nixCats package
├── checks/         flake checks
└── secrets/        sops-encrypted secrets
docs/  keyboard/  tf/  fuji-recipes/
```

Every `.nix` under `nix/modules/` is imported automatically on the platform
it targets (`hm_modules/desktop` and `darwin_modules` on the Macs,
`nix_modules` on NixOS), so a helper file that is not a module will break
evaluation.

## Commands

```bash
make help              # everything else
make build             # build the host named by `hostname -s`
make deploy            # switch it; work-mac needs HOSTNAME=work-mac
make deploy-rs-all-dry # nix flake check, then dry-run tiger, pika, cogsworth
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
make build-mac WORK_CONFIG=/Users/kondy/work/nix
```

The Makefile turns that into `--override-input work-config path:$WORK_CONFIG`.

## Secrets

sops-nix, keyed to age. Encrypted values live in `nix/secrets/secrets.yaml`;
the berkeley-mono and pragmata-pro fonts under `nix/pkgs/` are git-crypt
encrypted separately. A clone without the key still evaluates, but cannot
build any host with `hmFoundry.dev.enable`, which installs the fonts.

## Non-goals

Reusability, stability, and being a good example. This is optimised for one
person's workflow, `main` breaks when I am experimenting, and the modules
assume my specific hosts.

## Reference

- [terlar/nix-config](https://github.com/terlar/nix-config)
- [utdemir/dotfiles](https://github.com/utdemir/dotfiles)
- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)
