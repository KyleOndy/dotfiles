# Development module hub. Submodules in this directory are picked up
# automatically by getModules (flake.nix); this file only declares the
# umbrella enable flag they gate on.

{ lib, config, ... }:
with lib;
{
  options.hmFoundry.dev = {
    enable = mkEnableOption "General development utilities and configuration";
  };
}
