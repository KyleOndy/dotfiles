# Hosts

This is a description of the machines I manage with NixOS.

Going forward machines are named after animals. The specific animal has little
bearing on the function of the machine.

## [Alpha]

My daily driver laptop.
Currently a Lenevo T560.

## Sigma

Temporary host running various services. Will be replaced with a new system in
the near future.

## Tau

## Tiger (Future)

Catchall host.

- ZFS
- Media management
- Nix build hosts, x86_64-linux and aarch-64-linux via emulation.

## Cat (Future)

Utility host on trusted lan.

- DNS

## Dog (Future)

Utility host on DMZ

- DNS

## Leming{1,2,3}

- DMZ homelab hosts, typically in some kind of cluster

## work-mac

Reference darwin (macOS) configuration for work environments. This is a **template configuration** designed to be used in work forks of this repository.

Features:

- Base nix-darwin system configuration with sensible defaults
- Home-manager integration with workstation profile
- Conditional import pattern for work-specific overrides
- Homebrew integration for GUI applications
- Optimized for Apple Silicon (aarch64-darwin)

See [docs/work-forks.md](../../docs/work-forks.md) for details on using this in a work fork.

## work-wsl

Reference WSL (Windows Subsystem for Linux) configuration for work environments. This is a **template configuration** designed to be used in work forks of this repository.

Features:

- Home-manager only configuration (no NixOS system)
- WSL-specific utilities and Windows interop
- Workstation profile with development tools
- Conditional import pattern for work-specific overrides
- Optimized for x86_64-linux

See [docs/work-forks.md](../../docs/work-forks.md) for details on using this in a work fork.

[alpha]: ./alpha
