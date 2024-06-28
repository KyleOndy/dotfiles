# Kyle's dots and infrastructure

This repository holds all the configuration and assets required to setup
environments or infrastructure I control.

This repository is always in some form of evolution. I do try to keep `main` in
a working state for people who happen to stumble upon this repo. I make no
promises however, even to myself.

## Setup

```
# install nix
git clone https://github.com/kyleondy/dotfiles.git ~/src/dotfiles
cd ~/src/dotfiles
nix-shell -p direnv
direnv allow
make deploy

# post setup
git clone git@github.com:/kyleondy/password-store.git ~/.password-store
```

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

## Structure

My use cases:

Multiple node types

- laptop
- server
- VM

Multiple architectures

- x86_64
- aarch64-darwin
- ARM

Multiple roles

- personal
- work

Trying to not nest configuration files deeply. Ex, `flake.nix` imports
`foo.nix` which import `bar.nix` which uses `bazz.nix`. Try to keep everything
two layers deep. `flake.nix` can reference a file, but that file should not
reference any deeper.

Nodes have

- system configuration irrespective of a user
- zero or more users, with their own config
- the same user on node1 and node2 may have different configurations

Users can have "roles".

- Gaming
- Dev
- Document creation

## Goals

### Complete configuration

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
- **[keyboard/](./keyboard/)**: QMK config for my keyboards
- **[nix/](./nix/)**: configuration for Nix and NixOS
- **[notes/](./notes/)**: less structured documentation
- **[tf/](./tf/)**: terraform code

## Roadmap / Todo

This is a running list things that I would like to do in the future, when I
have time. They are in no specific order, nor are they encompassing.

### General

- look into [nvd](https://gitlab.com/khumba/nvd) as a replacement for `nix-diff`.
- cleanup old comments that are no longer valid throughout code base
- use [git worktrees] so large builds do not prevent me from working on other code changes
- automatically backup unifi console
- [setup apcupsd to shutdown homelab and tiger. Just leave up network gear util_lan after ~90 seconds of outage](https://brendonmatheson.com/2020/03/21/automated-remote-host-shutdown-with-apcupsd.html)

[git worktrees]: https://git-scm.com/docs/git-worktree

#### ZSH

- Look into caching with [evalcache](https://github.com/mroth/evalcache)

### Infrastructure

These are related to hosts opposed to dot files.

#### Bootstapping

- Be able to run `make netboot` and build a netboot image, and server it via [pixicore]
- write instructions, and script, on how to install NixOS on hardware
- Look into [Graham Christensen]'s work with [nix-netboot-serve] (pxe on
  demand). Possibly combine with [erase your darlings].

[pixiecore]: https://github.com/danderson/netboot/tree/master/pixiecore
[graham christensen]: https://twitter.com/grhmc
[nix-netboot-serve]: https://github.com/DeterminateSystems/nix-netboot-serve
[erase your darlings]: https://grahamc.com/blog/erase-your-darlings

#### Services

- Move tiger to DMZ. Lets me easily server content to internet, build host, apps, binary cache, etc.
  - IMPLICATION: will need backup ZFS server to PULL from this server since tiget can't reach out to it
- serve things under `apps.ondy.org`
- host under `apps.1ella.com`
  - setup wildcard `*.apps.1ella.com` to DDNS address of home
    - `sonarr.apps.1ella.com`
    - `radarr.apps.1ella.com`
    - `nzbget.apps.1ella.com`
    - `nzbhydra2.apps.1ella.com`
    - `jellyfin.apps.1ella.com`
    - `git.apps.1ella.com`
    - `concourse.apps.1ella.com`
    - `hydra.apps.1ella.com`
- setup vanity urls for `<foo>.ondy.org` as desired in TF
  - git.ondy.org
  - jellyfin.ondy.org
  - nixcache.ondy.org
  - ci.ondy.org

## External Resources

These are other people's dotfiles and articles I found useful while setting my environment up.
This list is in lexicographical order and not exclusive.

- [Terje Larsen's (terlar) dotfiles](https://github.com/terlar/nix-config)
- [Utku Demir's (utdemir) dotfiles](https://github.com/utdemir/dotfiles)
