{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable-small";
    nixos-hardware.url = "github:NixOS/nixos-hardware/";
    home-manager = {
      url = "github:nix-community/home-manager";
      # packages installed via home-manager use my nixpkgs
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      # packages installed via nix-darwin use my nixpkgs
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    nur.url = "github:nix-community/NUR";
    flake-utils.url = "github:numtide/flake-utils";
    sops-nix.url = "github:Mic92/sops-nix";
    nix-netboot-serve.url = "github:DeterminateSystems/nix-netboot-serve";
    deploy-rs.url = "github:serokell/deploy-rs";
    # https://hydra.nixos.org/job/nixos/trunk-combined/nixos.sd_image.aarch64-linux
    nixpkgs-raspberrypi.url = "github:nixos/nixpkgs/4d7c2644dbac9cf8282c0afe68fca8f0f3e7b2db";
    plasma-manager = {
      url = "github:pjones/plasma-manager";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
      };
    };
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
                prettier = {
                  enable = true;
                  excludes = [ "flake.lock" ];
                };
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
      }
      )
    // {
      nixosConfigurations = {
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
                deployment_target.enable = true;
                users.kyle.enable = true;
                desktop.kde.enable = true;
              };
              # TODO: overwriting for testing pourposes
              services = {
                power-profiles-daemon.enable = false; # am using tlp
                mullvad-vpn.enable = true;
              };

              nixpkgs.overlays = overlays;
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                sharedModules = hmModules ++ [
                  # TODO: make this module available to all machines
                  inputs.plasma-manager.homeManagerModules.plasma-manager
                ];
                users.kyle = {
                  imports = [ ./nix/profiles/full.nix ];

                  hmFoundry = {
                    desktop = {
                      browsers.qutebrowser.enable = true;
                      media.latex.enable = true;
                      term.foot.enable = true;
                      wm.kde.enable = true;
                    };
                  };
                };
              };
            }
          ];
        };
        tiger = inputs.nixpkgs.lib.nixosSystem
          {
            system = "x86_64-linux";
            modules = nixModules ++ [
              ./nix/hosts/tiger/configuration.nix
              inputs.sops-nix.nixosModules.sops
              inputs.nix-netboot-serve.nixosModules.nix-netboot-serve
              inputs.home-manager.nixosModules.home-manager
              {
                systemFoundry =
                  {
                    deployment_target.enable = true;
                    users.kyle.enable = true;
                  };
                nixpkgs.overlays = overlays;
                home-manager = {
                  useGlobalPkgs = true;
                  useUserPackages = true;
                  sharedModules = hmModules ++ [
                    # TODO: make this module available to all machines
                    inputs.plasma-manager.homeManagerModules.plasma-manager
                  ];
                  users.kyle = import ./nix/profiles/ssh.nix;
                };
              }
            ];
          };
        iso = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./nix/iso.nix
            "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            #inputs.sops-nix.nixosModules.sops
            #{
            #  nixpkgs.overlays = overlays;
            #}
          ];
        };
        sd_card = inputs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            "${inputs.nixpkgs-raspberrypi}/nixos/modules/installer/sd-card/sd-image-aarch64-new-kernel-installer.nix"
            {
              nixpkgs.config.allowUnsupportedSystem = true;
              system.stateVersion = "23.05";
            }
            ./nix/hosts/bootstrap.nix
          ];
        };
        pi1 = inputs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = nixModules ++ [
            inputs.nixos-hardware.nixosModules."raspberry-pi-4"
            ./nix/hosts/pi1/configuration.nix
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
                sharedModules = hmModules ++ [
                  # TODO: make this module available to all machines
                  # TODO: should this be available on machines we only ssh into?
                  inputs.plasma-manager.homeManagerModules.plasma-manager
                ];
                users.kyle = import ./nix/profiles/ssh.nix;
              };
            }
          ];
        };
      };

      # deploy-rs
      deploy = {
        fastConnection = true;
        nodes = {
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
          pi1 = {
            hostname = "pi1.lan.1ella.com";
            profiles.system = {
              sshUser = "svc.deploy";
              user = "root";
              path = inputs.deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.pi1;
            };
          };
        };
      };
    };
}
