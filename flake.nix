{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    # https://github.com/NixOS/nixpkgs/pull/427631
    nixpkgs-master.url = "github:nixos/nixpkgs/master";
    nixos-hardware.url = "github:NixOS/nixos-hardware/";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      # packages installed via home-manager use my nixpkgs
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      # packages installed via nix-darwin use my nixpkgs
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks.url = "github:cachix/git-hooks.nix";
    nur.url = "github:nix-community/NUR";
    flake-utils.url = "github:numtide/flake-utils";
    sops-nix.url = "github:Mic92/sops-nix";
    deploy-rs.url = "github:serokell/deploy-rs";
    # https://hydra.nixos.org/job/nixos/trunk-combined/nixos.sd_image.aarch64-linux
    plasma-manager = {
      url = "github:pjones/plasma-manager";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
      };
    };
    framework-dsp = {
      url = "github:cab404/framework-dsp";
      flake = false;
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    { self, ... }@inputs:
    let
      # import all the overlays that extend packages via nix or home-manager.
      overlays = [
        inputs.nur.overlays.default
        (import ./nix/pkgs)

        (final: _prev: {
          master = import inputs.nixpkgs-master {
            inherit (final) system config;
          };
        })
      ];

      # Profile registry for consistent profile management
      profiles = {
        minimal = ./nix/profiles/minimal.nix;
        server = ./nix/profiles/server.nix;
        ssh = ./nix/profiles/ssh.nix;
        workstation = ./nix/profiles/workstation.nix;
        gaming = ./nix/profiles/gaming.nix;
      };

      # Get all .nix files recursively from a directory
      getModules =
        path:
        let
          lib = inputs.nixpkgs.lib;
        in
        lib.filter (lib.hasSuffix ".nix") (lib.filesystem.listFilesRecursive path);

      # Split home-manager modules by category
      hmCoreModules =
        getModules ./nix/modules/hm_modules/dev
        ++ getModules ./nix/modules/hm_modules/shell
        ++ getModules ./nix/modules/hm_modules/terminal;
      hmDesktopModules = getModules ./nix/modules/hm_modules/desktop;
      nixModules = getModules ./nix/modules/nix_modules;

      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = inputs.nixpkgs.lib.genAttrs supportedSystems;

      # Helper function to create nixosSystem configurations
      mkNixosSystem =
        {
          hostname,
          system ? "x86_64-linux",
          isDesktop ? false,
          hardwareModules ? [ ],
          includeModules ? [ ],
          profile ? null,
          extraConfig ? { },
        }:
        inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules =
            nixModules
            ++ hardwareModules
            ++ includeModules
            ++ [
              ./nix/hosts/${hostname}/configuration.nix
              inputs.sops-nix.nixosModules.sops
              inputs.home-manager.nixosModules.home-manager
            ]
            ++ [
              (
                {
                  systemFoundry = {
                    deployment_target.enable = true;
                    users.kyle.enable = true;
                  }
                  // (if isDesktop then { desktop.kde.enable = true; } else { });

                  # Add git revision to generation labels
                  system.configurationRevision = self.rev or self.dirtyRev or "unknown";
                  system.nixos.label = self.shortRev or self.dirtyShortRev or "unknown";

                  nixpkgs.overlays = overlays;
                  home-manager = {
                    useGlobalPkgs = true;
                    useUserPackages = true;
                    sharedModules =
                      hmCoreModules
                      ++ (
                        if isDesktop then
                          hmDesktopModules
                          ++ [
                            inputs.plasma-manager.homeModules.plasma-manager
                          ]
                        else
                          [ ]
                      );
                    users.kyle =
                      let
                        baseProfile =
                          if profile != null then
                            { imports = [ profile ]; }
                          else if isDesktop then
                            { imports = [ profiles.workstation ]; }
                          else
                            { imports = [ profiles.ssh ]; };
                        extraUserConfig = extraConfig.home-manager.users.kyle or { };
                      in
                      baseProfile // extraUserConfig;
                  };
                }
                // (builtins.removeAttrs extraConfig [ "home-manager" ])
              )
            ];
        };
    in
    {

      checks = forAllSystems (system: {
        pre-commit-check =
          inputs.pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              black.enable = true;
              nixfmt-rfc-style.enable = true;
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
          # this functions outputs two checks defined in `deploy-rs`'s flake,
          # `deploy-schema` and `deploy-activate`.
          #
          # https://github.com/serokell/deploy-rs/blob/aa07eb05537d4cd025e2310397a6adcedfe72c76/flake.nix#L128
          // builtins.mapAttrs (_: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib;
      });

      devShells = forAllSystems (system: {
        default = inputs.nixpkgs.legacyPackages.${system}.mkShell {
          inherit (self.checks.${system}.pre-commit-check) shellHook;
          buildInputs = self.checks.${system}.pre-commit-check.enabledPackages;

          # Skip nix flake check in smart-test hook to speed up claude-code
          CLAUDE_SKIP_NIX_TESTS = "true";
        };
      });

      nixosConfigurations = {
        dino = mkNixosSystem {
          hostname = "dino";
          isDesktop = true;
          hardwareModules = [
            inputs.nixos-hardware.nixosModules.framework-12th-gen-intel
          ];
          includeModules = [
            # todo: refactor these into something else
            ./nix/hosts/_includes/common.nix
            ./nix/hosts/_includes/docker.nix
            ./nix/hosts/_includes/kvm.nix
            ./nix/hosts/dino/root-ssh-config.nix
            inputs.disko.nixosModules.disko
            ./disko-config.nix
          ];
          extraConfig = {
            services = {
              power-profiles-daemon.enable = false; # am using tlp
            };
            programs.dconf.enable = true; # fw13 dsp
            home-manager.users.kyle = {
              hmFoundry = {
                desktop = {
                  media.latex.enable = true;
                  wm.kde.enable = true;
                };
                dev = {
                  hashicorp.enable = inputs.nixpkgs.lib.mkForce true;
                  claude-code = {
                    enable = true;
                    enableNotifications = true;
                  };
                };
              };
              # dsp for fw13
              services.easyeffects = {
                enable = true;
              };
              xdg.configFile = {
                "easyeffects/output/cab-fw.json" = {
                  source = "${inputs.framework-dsp}/config/output/Gracefu's Edits.json";
                };
              };
            };
          };
        };
        tiger = mkNixosSystem {
          hostname = "tiger";
          profile = profiles.ssh;
        };
        cheetah = mkNixosSystem {
          hostname = "cheetah";
          profile = profiles.ssh;
        };
        iso = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./nix/iso.nix
            "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ];
        };
        installer = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            inputs.disko.nixosModules.disko
            (
              { pkgs, ... }:
              {
                environment.systemPackages = with pkgs; [
                  inputs.disko.packages.x86_64-linux.disko
                  git
                  neovim
                  tmux
                ];

                nix.settings.experimental-features = [
                  "nix-command"
                  "flakes"
                ];

                environment.etc."installer".source = self;
                environment.etc."install.sh" = {
                  source = pkgs.writeShellScript "install.sh" ''
                    set -e

                    echo "install"
                    echo "partitioning disk"
                    sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko -- \
                      --mode disko /etc/installer/disko-config.nix

                    echo "gen config"
                    sudo nixos-generate-config --no-filesystems --root /mnt

                    echo copying flake
                    sudo cp -r /etc/installer /mnt/etc/nixos

                    echo installing
                    sudo nixos-install --flake /mnt/etc/nixos/installer#dino

                    echo done
                    echo run sudo reboot
                  '';
                  mode = "0755";
                };
                services.getty.helpLine = ''
                  To install: sudo /etc/install.sh
                '';

              }
            )
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
          cheetah = {
            fastConnection = false;
            hostname = "cheetah";
            profiles.system = {
              sshUser = "svc.deploy";
              user = "root";
              path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.cheetah;
            };
          };
        };
      };
    };
}
