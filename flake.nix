{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    neovim-nightly-overlay = {
      url = "github:mjlbach/neovim-nightly-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nur = {
      url = "github:nix-community/NUR";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, ... }@inputs:
    # this allows us to get the propper `system` whereever we are running
    inputs.flake-utils.lib.eachDefaultSystem
      (system: {
        checks = {
          pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              black.enable = true;
              nixpkgs-fmt.enable = true;
              prettier.enable = true;
              shellcheck.enable = true;
              yamllint.enable = true;
            };
          };
        };
        devShell = inputs.nixpkgs.legacyPackages.${system}.mkShell {
          inherit (self.checks.${system}.pre-commit-check) shellHook;
        };
      })
    // {
      nixosConfigurations.alpha =
        inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./hosts/alpha/configuration.nix
            ./hosts/alpha/hardware-configuration.nix
            inputs.home-manager.nixosModules.home-manager
            {
              nixpkgs.overlays = [
                inputs.neovim-nightly-overlay.overlay
                inputs.nur.overlay
              ] ++
              # import all the overlays that extend packages via nix or
              # home-manager. Overlays are a nix file within the `overlay` folder
              # or a sub folder in `overlay` that contains a `default.nix`.
              (
                let
                  path = ./home/overlays;
                in
                with builtins;
                map (n: import (path + ("/" + n))) (
                  filter
                    (
                      n:
                      match ".*\\.nix" n != null
                      || pathExists (path + ("/" + n + "/default.nix"))
                    )
                    (attrNames (readDir path))
                )
              );
            }
          ];
        };
    };
}
