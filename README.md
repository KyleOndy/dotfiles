# Kyle's dots and infrastructure

This repository holds all the configuration and assets required to setup
environments or infrastructure I control.

This repository is always in some form of evolution. I do try to keep `main` in
a working state for people who happen to stumble upon this repo. I make no
promises however, even to myself.

## Tooling

I use [NixOS] as my operating system whenever possible. To manage my user
environment I use [`home-manager`]. I use [flakes] to pin my dependencies.

When I am unable to use [NixOS], I still try and use [home-manager] and use nix
onto of the OS. On MacOS systems I use [nix-darwin] to manage as much of the
system as I can.

I use [terraform] to manage any infrastructure within [AWS].

[nixos]: https://nixos.org/
[home-manager]: https://github.com/rycee/home-manager
[flaks]: https://nixos.wiki/wiki/Flakes
[nix-darwin]: https://github.com/LnL7/nix-darwin
[terraform]: https://www.terraform.io/
[aws]: https://aws.amazon.com/

## Goals

### Complete configuraiton

To define configuration for everything that plugs into a wall in this single
repository.

### Learning

I may do things the hard way to help me learn things.

## Non-Goals

The following are things they I feel need to be explicitly called out.

### Reference architecture for best practices

This repository is my metaphorical tool belt I wear at my day job. Sometimes I
need to get things done, and I do it without much concern. I will try to leave
a `// todo:` for the future, but do not assume any confusing code is done for a
good reason.

### Reusability

To improve how quickly I can iterate, I do not write any of the code in this
repository with the goal of having it easy for someone to reuse. I am thrilled
if people can be inspired by my code, but I don't there will be much success
blindly copying code.

## Repository layout

This is a top level layout. Each directory should have a README that provides
more detail.

- **[bin/](./bin/)**: scripts used in the management of this repo
- **[docs/](./docs/)**: detailed documentation on specific topics
- **[keyboard/](./keyboard/)**: QMK config for my kepboards
- **[nix/](./nix/)**: configuration for Nix and NixOS
- **[notes/](./notes/)**: less structured documentation

## External Resources

These are other people's dotfiles and articles I found useful while setting my environment up.
This list is in lexicographical order and not exclusive.

- [Terje Larsen's (terlar) dotfiles](https://github.com/terlar/nix-config)
- [Utku Demir's (utdemir) dotfiles](https://github.com/utdemir/dotfiles)
