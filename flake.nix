{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    neovim-nightly-overlay.url = "github:mjlbach/neovim-nightly-overlay";
    nur.url = github:nix-community/NUR;

  };
  outputs = { self, ... }@inputs: {
    nixosConfigurations.alpha =
      inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          #./system.nix
          #./hardware.nix
          ./hosts/alpha/configuration.nix
          ./hosts/alpha/hardware-configuration.nix
          inputs.home-manager.nixosModules.home-manager
          #inputs.nixos-hardware.nixosModules.lenovo-thinkpad-t480s
          {
            nixpkgs.overlays = [
              inputs.neovim-nightly-overlay.overlay
              inputs.nur.overlay
            ];
          }
        ];
      };
  };
}
