{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable-small";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    nur.url = "github:nix-community/NUR";
    flake-utils.url = "github:numtide/flake-utils";
    sops-nix.url = "github:Mic92/sops-nix";
    nix-netboot-serve.url = "github:DeterminateSystems/nix-netboot-serve";
    deploy-rs.url = "github:serokell/deploy-rs";
  };
  outputs = { self, ... }@inputs:
    let
      # import all the overlays that extend packages via nix or home-manager.
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
    inputs.flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-linux" ]
      (system: {
        checks = {
          pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run
            {
              src = ./.;
              hooks = {
                black.enable = true;
                nixpkgs-fmt.enable = true;
                prettier.enable = true;
                shellcheck.enable = true;
                stylua.enable = true;
                pkg_version = {
                  enable = false;
                  name = "pkg-version-bump";
                  entry = "bin/pre-commit-update-version";
                  files = "^nix/pkgs/.*?/default\.nix$";
                  language = "script";
                  pass_filenames = true;
                };
              };
            }
          // builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib;
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
              systemFoundry =
                {
                  deployment_target.enable = true;
                };
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
        dino = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = nixModules ++ [
            inputs.nixos-hardware.nixosModules.framework-12th-gen-intel
            ./nix/hosts/dino/configuration.nix
            ./nix/hosts/dino/hardware-configuration.nix

            # todo: refactor these into something else
            ./nix/hosts/_includes/common.nix
            ./nix/hosts/_includes/docker.nix
            ./nix/hosts/_includes/kvm.nix
            ./nix/hosts/_includes/laptop.nix
            ./nix/hosts/_includes/wifi_networks.nix

            inputs.sops-nix.nixosModules.sops
            inputs.home-manager.nixosModules.home-manager
            {
              systemFoundry = {
                users.kyle.enable = true;
                deployment_target.enable = true;
              };
              # TODO: overwriting for testing pourposes
              services = {
                xserver = {
                  displayManager = {
                    sddm.enable = true;
                    defaultSession = "plasmawayland";
                  };
                  desktopManager.plasma5.enable = true;
                };
                power-profiles-daemon.enable = false; # am using tlp
                mullvad-vpn.enable = true;
              };

              nixpkgs.overlays = overlays;
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                sharedModules = hmModules;
                users.kyle = {
                  imports = [ ./nix/profiles/full.nix ];

                  hmFoundry = {
                    desktop = {
                      browsers.qutebrowser.enable = true;
                      wm.i3.enable = inputs.nixpkgs.lib.mkForce false;
                    };
                  };


                  programs = {
                    foot = {
                      enable = true;
                      settings = {
                        main = {
                          font = "Hack:size=7";
                          dpi-aware = "yes";
                        };
                        cursor = {
                          blink = "yes";
                        };
                        mouse = {
                          hide-when-typing = "yes";
                        };
                      };
                    };
                  };
                };


              };
            }
          ];
        };
        util_lan = inputs.nixpkgs.lib.nixosSystem
          {
            system = "aarch64-linux";
            modules = nixModules ++ [
              ./nix/hosts/util_lan/configuration.nix
              inputs.sops-nix.nixosModules.sops
              inputs.home-manager.nixosModules.home-manager
              {
                systemFoundry = {
                  deployment_target.enable = true;
                  users.kyle.enable = true;
                };
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
        tiger = inputs.nixpkgs.lib.nixosSystem
          {
            system = "x86_64-linux";
            modules = nixModules ++ [
              ./nix/hosts/tiger/configuration.nix
              ./nix/users/kyle.nix
              inputs.sops-nix.nixosModules.sops
              inputs.nix-netboot-serve.nixosModules.nix-netboot-serve
              inputs.home-manager.nixosModules.home-manager
              {
                systemFoundry =
                  {
                    deployment_target.enable = true;
                  };
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
        dmz_rp = inputs.nixpkgs.lib.nixosSystem
          {
            system = "aarch64-linux";
            modules = nixModules ++ [
              ./nix/hosts/dmz_rp/configuration.nix
              inputs.sops-nix.nixosModules.sops
              inputs.home-manager.nixosModules.home-manager
              {
                systemFoundry = {
                  deployment_target.enable = true;
                  users.kyle.enable = true;
                };
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
      darwinConfigurations.DCP40KQJX6 = inputs.nix-darwin.lib.darwinSystem
        {
          system = "aarch64-darwin";
          modules = [
            ./nix/hosts/DCP40KQJX6/configuration.nix
            inputs.home-manager.darwinModules.home-manager
            {
              nixpkgs.overlays = overlays;
              users.users."kyle.ondy".home = "/Users/kyle.ondy"; # TODO: need this?
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                sharedModules = hmModules;
                users."kyle.ondy" = {
                  imports = [ ./nix/profiles/s1.nix ];
                };
              };
            }
          ];
        };
      DCP40KQJX6 = self.darwinConfigurations.DCP40KQJX6.system;

      # deploy-rs
      deploy.nodes = {
        dino = {
          hostname = "dino";
          profiles.system = {
            sshUser = "svc.deploy";
            user = "root";
            path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.dino;
          };
        };
        tiger = {
          hostname = "tiger";
          profiles.system = {
            sshUser = "svc.deploy";
            user = "root";
            path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.tiger;
          };
        };
        util_lan = {
          hostname = "util.lan.509ely.com";
          profiles.system = {
            sshUser = "svc.deploy";
            user = "root";
            path = inputs.deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.util_lan;
          };
        };
        dmz_rp = {
          hostname = "10.25.89.10"; # "rp.dmz.509ely.com";
          profiles.system = {
            sshUser = "svc.deploy";
            user = "root";
            path = inputs.deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.dmz_rp;
          };
        };
      };
    };
}
