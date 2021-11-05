# Kyle's nix(os)-config and dots

This repository is always in some form of evolution. I do try to keep `main` in
a working state for people who happen to stumble upon this repo. I make no
promises however, even to myself.

## Overview

I use [NixOS] as my operating system whenever possible. To manage my user
environment I use [`home-manager`]. I use [flakes] to pin my dependencies.

When I am unable to use [NixOS], I still try and use [home-manager] and use nix
onto of the OS. On MacOS systems I use [nix-darwin] to manage as much of the
system as I can.

[nixos]: https://nixos.org/
[home-manager]: https://github.com/rycee/home-manager
[flaks]: https://nixos.wiki/wiki/Flakes
[nix-darwin]: https://github.com/LnL7/nix-darwin

## Goals

NixOS is a fully declarative operating system, configuration is centralized and
applied via the native Nix tooling and `home-manager`. This approach allows me
to easily and confidently apply changes. Another benefit is quickly bringing a
new machine to my desired state.

## Repository layout

```bah
.
├── home                      # contains home manager config
│   ├── _dots_not_yet_in_nix/ # dotfiles that have not been migrated into home-manager
│   ├── home.nix              # entrypoint to home-manager, and a catch all for configuraiton
│   ├── *.nix                 # each `.nix` file holds home-manager configuraiton
├── hosts                     # host configuration for NixOS
│   ├── */                    # each subdirectotry hold a single machines configuration
│   ├── _includes/            # nix configuraiton used by multipules hosts
│   ├── README.md             # more detailed information about hosts
├── .editorconfig             # keeping the style sane
├── .envrc                    # automatically load shell.nix
├── keyboard                  # ergodox_ez / qmk configuration
├── nix                       # dependency pinning with niv
├── make.sh                   # script to build / switch / update the system
├── default.nix               # needed for dependency pinning and pre-commit checks
└── shell.nix                 # setting up the project environment
```

## Roadmap / Todo

Some random thoughts on how to make things better

- Don't switch NixOS configuration if no change.
  Faster and no password needed.
- Support nix-darwin (new work computer)

## External Resources

These are other people's dotfiles and articles I found useful while setting my environment up.
This list is in lexicographical order.

- [Terje Larsen's (terlar) dotfiles](https://github.com/terlar/nix-config)
- [Utku Demir's (utdemir) dotfiles](https://github.com/utdemir/dotfiles)
