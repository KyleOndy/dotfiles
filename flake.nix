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
      url = "github:LnL7/nix-darwin/nix-darwin-25.05";
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
    nixCats = {
      url = "github:BirdeeHub/nixCats-nvim";
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
      # Each profile specifies:
      # - homeModule: path to home-manager configuration
      # - needsDesktop: whether desktop modules and environment are required
      #
      # Available profiles:
      # - server: Headless systems accessed via SSH (full dev tools, no GUI)
      # - desktop: Systems with physical access and GUI (full dev tools + desktop apps)
      profiles = {
        server = {
          homeModule = ./nix/profiles/server.nix;
          needsDesktop = false;
        };
        desktop = {
          homeModule = ./nix/profiles/desktop.nix;
          needsDesktop = true;
        };
        kiosk = {
          homeModule = ./nix/profiles/kiosk.nix;
          needsDesktop = false;
        };
      };

      # nixCats configuration for Neovim
      inherit (inputs.nixCats) utils;
      # Create the custom home-manager module for nixCats
      # Category and package definitions are in nix/nixcats/
      nixCatsHomeModule = utils.mkHomeModules {
        moduleNamespace = [ "nvim" ];
        inherit (inputs) nixpkgs;
        dependencyOverlays = [ ];
        luaPath = ./nix/modules/hm_modules/terminal/editors/neovim/lua;
        categoryDefinitions = import ./nix/nixcats/categories.nix;
        packageDefinitions = import ./nix/nixcats/packages.nix;
        defaultPackageName = "nvim";
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
      # Profile is now required and must be specified from the profiles registry
      mkNixosSystem =
        {
          hostname,
          system ? "x86_64-linux",
          hardwareModules ? [ ],
          includeModules ? [ ],
          profile, # Required - no default
          extraConfig ? { },
        }:
        let
          profileConfig = profiles.${profile};
          isDesktop = profileConfig.needsDesktop;
        in
        inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit inputs;
          };
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
                    extraSpecialArgs = {
                      dotfiles-root = self.outPath;
                      inherit inputs;
                    };
                    sharedModules =
                      hmCoreModules
                      ++ [ nixCatsHomeModule ]
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
                        baseProfile = {
                          imports = [ profileConfig.homeModule ];
                        };
                        extraUserConfig = extraConfig.home-manager.users.kyle or { };
                      in
                      baseProfile // extraUserConfig;
                  };
                }
                // (builtins.removeAttrs extraConfig [ "home-manager" ])
              )
            ];
        };

      # Helper function to create darwinSystem configurations
      # Profile is now required and must be specified from the profiles registry
      mkDarwinSystem =
        {
          hostname,
          system ? "aarch64-darwin",
          includeModules ? [ ],
          profile, # Required - no default
          username ? "kyle.ondy",
          extraConfig ? { },
        }:
        let
          profileConfig = profiles.${profile};
          isDesktop = profileConfig.needsDesktop;
          hostHomeConfig = ./nix/hosts/${hostname}/home.nix;
        in
        inputs.nix-darwin.lib.darwinSystem {
          inherit system;
          modules = [
            ./nix/hosts/${hostname}/configuration.nix
            inputs.home-manager.darwinModules.home-manager
          ]
          ++ includeModules
          ++ [
            (
              {
                nixpkgs.overlays = overlays;
                users.users.${username}.home = "/Users/${username}";
                home-manager = {
                  useGlobalPkgs = true;
                  useUserPackages = true;
                  extraSpecialArgs = {
                    dotfiles-root = self.outPath;
                    inherit inputs;
                  };
                  # Include desktop modules for cross-platform validation
                  # This allows desktop modules to reference programs.plasma without evaluation errors
                  sharedModules =
                    hmCoreModules
                    ++ [ nixCatsHomeModule ]
                    ++ (
                      if isDesktop then
                        hmDesktopModules
                        ++ [
                          inputs.plasma-manager.homeModules.plasma-manager
                        ]
                      else
                        [ ]
                    );
                  users.${username} = {
                    imports = [
                      profileConfig.homeModule
                    ]
                    ++ (if builtins.pathExists hostHomeConfig then [ hostHomeConfig ] else [ ]);
                  };
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

      packages = forAllSystems (
        system:
        let
          pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = overlays;
            config = { };
          };
        in
        {
          # Expose internal packages for direct building and benchmarking
          git-worktree-prompt = pkgs.git-worktree-prompt;
        }
      );

      nixosConfigurations = {
        dino = mkNixosSystem {
          hostname = "dino";
          profile = "desktop";
          hardwareModules = [
            inputs.nixos-hardware.nixosModules.framework-12th-gen-intel
          ];
          includeModules = [
            ./nix/hosts/dino/root-ssh-config.nix
            inputs.disko.nixosModules.disko
            ./disko-config.nix
          ];
        };
        tiger = mkNixosSystem {
          hostname = "tiger";
          profile = "desktop";
        };
        wolf = mkNixosSystem {
          hostname = "wolf";
          profile = "server";
        };
        bear = mkNixosSystem {
          hostname = "bear";
          profile = "server";
          includeModules = [
            inputs.disko.nixosModules.disko
            ./nix/hosts/bear/nix-anywhere/disk-config.nix
          ];
        };
        cogsworth = mkNixosSystem {
          hostname = "cogsworth";
          system = "aarch64-linux";
          profile = "server";
          hardwareModules = [
            inputs.nixos-hardware.nixosModules.raspberry-pi-4
          ];
          extraConfig = {
            home-manager.users.kyle = {
              hmFoundry.dev.terraform.enable = inputs.nixpkgs.lib.mkForce false;
            };
          };
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
      darwinConfigurations.work-mac = mkDarwinSystem {
        hostname = "work-mac";
        profile = "desktop";
        username = "kyle.ondy";
      };

      homeConfigurations."kyle@work-wsl" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
        extraSpecialArgs = {
          dotfiles-root = self.outPath;
          inherit inputs;
        };
        modules =
          hmCoreModules
          ++ [ nixCatsHomeModule ]
          ++ [
            ./nix/hosts/work-wsl/home.nix
            {
              nixpkgs.overlays = overlays;
              nixpkgs.config.allowUnfree = true;
            }
          ];
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
          wolf = {
            fastConnection = false;
            hostname = "51.79.99.201";
            profiles.system = {
              sshUser = "svc.deploy";
              user = "root";
              path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.wolf;
            };
          };
          bear = {
            fastConnection = false;
            hostname = "147.135.8.156";
            profiles.system = {
              sshUser = "svc.deploy";
              user = "root";
              path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.bear;
            };
          };
          cogsworth = {
            hostname = "cogsworth";
            profiles.system = {
              sshUser = "svc.deploy";
              user = "root";
              path = inputs.deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.cogsworth;
            };
          };
        };
      };
    };
}
