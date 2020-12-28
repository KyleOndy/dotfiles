{
  description = "NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    neovim-nightly-overlay.url = "github:mjlbach/neovim-nightly-overlay";
  };


  outputs = { self, ... }@inputs: {
    nixosConfigurations."${(import ./user.nix).hostname}" =
      inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/alpha/configuration.nix
          ./hosts/alpha/hardware-configuration.nix
          inputs.home-manager.nixosModules.home-manager
          #inputs.nixos-hardware.nixosModules.lenovo-thinkpad-t480s
          { nixpkgs.overlays = [ inputs.neovim-nightly-overlay.overlay ]; }
        ];
      };
  };
}
