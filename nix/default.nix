let
  sources = import ./sources.nix;
  configuration = {
    imports = [
      ../hosts/alpha/configuration.nix
      "${sources.home-manager}/nixos"
    ];
    #nixpkgs.config.allowBroken = true;
  };
in
(import "${sources.nixpkgs}/nixos" { inherit configuration; }).system
