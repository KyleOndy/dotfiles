{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable-small";
    home-manager = {
      url = "github:nix-community/home-manager/master";
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
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    sops-nix.url = "github:Mic92/sops-nix";
  };
  outputs = { self, ... }@inputs:
    let
      # import all the overlays that extend packages via nix or home-manager.
      # Overlays are a nix file within the `overlay` folder or a sub folder in
      # `overlay` that contains a `default.nix`.
      overlays = [
        inputs.nur.overlay
        (import ./nix/pkgs)
        (import ./nix/overlays/st)
      ];


      # I am sure this is ugly to experienced nix users, and might break in all
      # kinds of unexpected ways. This was my first actual function written in
      # nix, and I never really figured out the repl, this is what I ended up
      # with.
      #
      # This function takes a path, and returns a list of every file under it.
      #
      # TODO:
      #   - filter by .nix
      #   - handles readDir's `symlink` and `unknown` types
      #   - is there a better way than (path + ("/" + path))?
      #   - can this be moved into a library and sourced over inline?
      getModules = path:
        let
          lib = inputs.nixpkgs.lib;
          getNixFilesRec = path:
            let
              contents = builtins.readDir path;
              files = builtins.attrNames (lib.filterAttrs (_: v: v == "regular") contents);
              dirs = builtins.attrNames (lib.filterAttrs (_: v: v == "directory") contents);
              nixFiles = lib.filter (p: lib.hasSuffix ".nix" p) files;
            in
            # return the path of all files found in this directory
            (map (p: path + ("/" + p)) nixFiles)
            ++
            # pass each directory into this function again
            (lib.concatMap (d: getNixFilesRec (path + ("/" + d))) dirs);
        in
        getNixFilesRec path;

      hmModules = getModules ./nix/modules/hm_modules;
      nixModules = getModules ./nix/modules/nix_modules;
    in
    # this allows us to get the propper `system` whereever we are running
    inputs.flake-utils.lib.eachSystem [ "x86_64-darwin" "x86_64-linux" ]
      (system: {
        checks = {
          pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              black.enable = true;
              nixpkgs-fmt.enable = true;
              prettier.enable = true;
              shellcheck.enable = true;
            };
          };
        };
        devShell = inputs.nixpkgs.legacyPackages.${system}.mkShell {
          inherit (self.checks.${system}.pre-commit-check) shellHook;
        };
      })
    // {
      nixosConfigurations = {
        alpha = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = nixModules ++ [
            ./nix/hosts/alpha/configuration.nix
            ./nix/hosts/alpha/hardware-configuration.nix

            ./nix/users/kyle.nix # todo: some service user

            # todo: refactor these into something else
            ./nix/hosts/_includes/common.nix
            ./nix/hosts/_includes/docker.nix
            ./nix/hosts/_includes/kvm.nix
            ./nix/hosts/_includes/laptop.nix
            ./nix/hosts/_includes/wifi_networks.nix

            inputs.sops-nix.nixosModules.sops
            inputs.home-manager.nixosModules.home-manager
            {
              systemFoundry.deployment_target.enable = true;
              nixpkgs.overlays = overlays;
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                sharedModules = hmModules;
                users.kyle = import ./nix/profiles/full.nix;
              };
            }
          ];
        };
        util_lan = inputs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = nixModules ++ [
            ./nix/hosts/util_lan/configuration.nix
            inputs.sops-nix.nixosModules.sops
            { systemFoundry.deployment_target.enable = true; }
          ];
        };
        util_dmz = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = nixModules ++ [
            ./nix/hosts/util_dmz/configuration.nix
            inputs.sops-nix.nixosModules.sops
            { systemFoundry.deployment_target.enable = true; }
          ];
        };
        reverse_proxy = inputs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = nixModules ++ [
            ./nix/hosts/reverse_proxy/configuration.nix
            inputs.sops-nix.nixosModules.sops
            { systemFoundry.deployment_target.enable = true; }
          ];
        };
        w2 = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = nixModules ++ [
            ./nix/hosts/w2/configuration.nix
            inputs.sops-nix.nixosModules.sops
            { systemFoundry.deployment_target.enable = true; }
          ];
        };
        tiger = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = nixModules ++ [
            ./nix/hosts/tiger/configuration.nix
            ./nix/users/kyle.nix
            inputs.sops-nix.nixosModules.sops
            inputs.home-manager.nixosModules.home-manager
            {
              systemFoundry.deployment_target.enable = true;
              nixpkgs.overlays = overlays;
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                sharedModules = hmModules;
                users.kyle = import ./nix/profiles/ssh.nix;
              };
            }
          ];
        };
      };
      darwinConfigurations.C02CL8GXLVDL = inputs.nix-darwin.lib.darwinSystem {
        system = "x86_64-darwin";
        modules = [
          ./nix/hosts/C02CL8GXLVDL/configuration.nix
          inputs.home-manager.darwinModule
          {
            nixpkgs.overlays = overlays;
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              sharedModules = hmModules;
              users."kyle.ondy" = {
                imports = [ ./nix/profiles/ssh.nix ];

                # darwin overrides. This is ripe for refactoring. Declaring
                # this in the flake so it is very clear what is happening.
                services.lorri.enable = inputs.nixpkgs.lib.mkForce false;
                hmFoundry = inputs.nixpkgs.lib.mkForce {
                  terminal = {
                    email.enable = false;
                    gpg = {
                      enable = true;
                      service = false; # no service on darwin
                    };
                  };
                };
              };
            };
          }
        ];
      };
      alpha = self.nixosConfigurations.alpha.config.system.build.toplevel;
      C02CL8GXLVDL = self.darwinConfigurations.C02CL8GXLVDL.system;
      rp = self.nixosConfigurations.reverse_proxy.config.system.build.toplevel;
      tiger = self.nixosConfigurations.tiger.config.system.build.toplevel;
      util_dmz = self.nixosConfigurations.util_dmz.config.system.build.toplevel;
      util_lan = self.nixosConfigurations.util_lan.config.system.build.toplevel;
      w2 = self.nixosConfigurations.w2.config.system.build.toplevel;
    };
}
