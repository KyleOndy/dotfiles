# Kyle's nix(os)-config and dots

This repository is always in some form of evolution.
I do try to keep `master` working as expected, but I make no promises, even to myself.

## Overview

I use [NixOS](https://nixos.org/) as my primary daily driver.
To manage my user environment I use [home-manager](https://github.com/rycee/home-manager).


NixOS is a fully declarative operating system, so configuration is centralized and applied via the native Nix tooling and home-manager.
This approach is different that configuration is not done with standard dotfiles.
Dotfiles are generated artifacts from the build process.

I have not yet had the opportunity to cut all my configuration over yet, so some dotfiles are just linked through for now.

## Repository layout

```bah
.
├── grep.sh                   # to search just ./home and ./hosts
├── home                      # contains home manager config
│   ├── _dots_not_yet_in_nix/ # dotfiles that have not been converter or are not supported by home-manager
│   ├── home.nix              # home.nix is the entrypoint to home-manager, and a catch all for configuraiton
│   ├── *.nix                 # each `nix` file holds home-manager configuraiton
│   ├── tag-*/                # dotfiles from `rcm` that I have not migrated yet
├── home-manager/             # submodule of home-manager
├── hosts                     # host configuration for NixOS
│   ├── */                    # each subdirectotry hold a single machines configuration
│   ├── _includes/            # nix configuraiton used by multipules hosts
│   ├── README.md             # more detailed information about hosts
├── Makefile                  # entrypoint to this repo. `make help` for more documentation
├── nixpkgs/                  # submodule of nixpkgs
└── README.md
```

## Roadmap

- migrate the rest of my dotfiles
- document the process more completely in this README
- Move any sensitive information out of this repository
  - wifi psk

### ToDo

- Add weechat
- add rss (newsboat)
- cleanup fonts
- add tarsnap

## External Resources

These are other people's dotfiles and articles I found useful while setting my environment up.

- [utdemir's dotfiles](https://github.com/utdemir/dotfiles)
- https://github.com/terlar/nix-config
