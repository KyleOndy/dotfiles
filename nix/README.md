# Nix

This directory contains all configuration for my NixOS hosts and nix packages/

## Structure

```txt

A simplified overview of the layout of this directory.

.
├── hosts
│   └── <foobar>
│       ├── configuration.nix
│       └── hardware-configuration.nix
├── modules
│   ├── hm_modules        # modules to apply via home-manager
│   └── nix_modules       # modules to apply to base nix
├── pkgs
│   ├── <foo_pkg>         # a nix package defined locally
│   │   └── default.nix
│   └── <overlay_pkg>     # a package overlay
│       ├── default.nix
│       └── foo.diff
├── profiles              # user profiles
├── secrets               # secrets via sops
└── users                 # user definition
```
