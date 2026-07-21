{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-master.url = "github:nixos/nixpkgs/master";
    claude-code-nix = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/";
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      # packages installed via home-manager use my nixpkgs
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # trex runs Determinate Nix; this brings in its nix-darwin integration
    # module (determinateNix.*), including its Determinate-compatible local
    # Linux VM builder. Deliberately not following our own nixpkgs -- this
    # feeds Determinate's own `nix` build, which they pin and test against.
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
    nix-darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-25.11";
      # packages installed via nix-darwin use my nixpkgs
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mcp-servers-nix = {
      url = "github:natsukium/mcp-servers-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
    mac-app-util.url = "github:hraban/mac-app-util";
    claude-skills-jeffallan = {
      url = "github:jeffallan/claude-skills";
      flake = false;
    };
    claude-skills-voltagent = {
      url = "github:VoltAgent/awesome-claude-code-subagents";
      flake = false;
    };
    claude-skills-rohitg00 = {
      url = "github:rohitg00/awesome-claude-code-toolkit";
      flake = false;
    };
    claude-skills-adhd = {
      url = "github:ayghri/i-have-adhd";
      flake = false;
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
    };
    cogsworth = {
      url = "git+ssh://git@github.com/KyleOndy/cogsworth?ref=v3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Work-specific configuration. Default is a no-op stub.
    # Override on work machines: --override-input work-config path:/Users/kondy/work
    work-config.url = "path:./nix/work-config-stub";
  };
  outputs =
    { self, ... }@inputs:
    let
      # Working-tree path captured from the DOTFILES_WORKTREE env var (set
      # by the Makefile via `git rev-parse --show-toplevel`). Used by
      # home-manager modules that want mkOutOfStoreSymlink to point at the
      # *worktree* being deployed from — not the store snapshot, not a
      # hardcoded path. Empty/null when the flake is evaluated in pure
      # mode or outside `make`; the consuming module throws with a clear
      # message in that case.
      dotfilesWorktree =
        let
          env = builtins.getEnv "DOTFILES_WORKTREE";
        in
        if env != "" then env else null;

      # import all the overlays that extend packages via nix or home-manager.
      overlays = [
        inputs.nur.overlays.default
        inputs.cogsworth.overlays.default
        (
          let
            d = self.lastModifiedDate or "unknown";
            buildDate =
              if d == "unknown" then
                "unknown"
              else
                "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";
          in
          import ./nix/pkgs {
            rev = self.rev or self.dirtyRev or "unknown";
            inherit buildDate;
          }
        )

        (final: _prev: {
          master = import inputs.nixpkgs-master {
            inherit (final.stdenv.hostPlatform) system;
            inherit (final) config;
          };
        })

        (final: _prev: {
          claude-code = inputs.claude-code-nix.packages.${final.stdenv.hostPlatform.system}.default;
        })

        inputs.llm-agents.overlays.default

        # TODO: remove once direnv fixes fish test sandbox kills on macOS
        # direnv 2.37.1 fish tests get Killed: 9 in macOS sandbox during nix build
        (_final: prev: {
          direnv = prev.direnv.overrideAttrs (_old: {
            doCheck = false;
          });
        })

        # pyopen-wakeword segfaults during installCheckPhase on aarch64
        # (numpy crash). Build wyoming-openwakeword against a Python with
        # patched package set so pyopen-wakeword skips the broken phase.
        (
          _final: prev:
          let
            python3 = prev.python3.override {
              packageOverrides = _pfinal: pprev: {
                pyopen-wakeword = pprev.pyopen-wakeword.overrideAttrs {
                  doInstallCheck = false;
                };
              };
            };
          in
          {
            wyoming-openwakeword = prev.wyoming-openwakeword.override {
              python3Packages = python3.pkgs;
            };
          }
        )

        # notmuch's own ./configure probes for -fsanitize=address/=thread
        # support by compiling AND RUNNING a trivial ASan/TSan binary. On
        # aarch64-darwin, ASan's runtime deadlocks during its own init
        # (recursive malloc into a non-reentrant spinlock while walking the
        # dyld shared cache for shadow-memory setup) -- an upstream
        # compiler-rt/macOS bug, unrelated to notmuch or the nix sandbox.
        # These probes only gate notmuch's own test-suite sanitizer variants
        # (test/T800-asan.sh, test/T810-tsan.sh), which already never run on
        # darwin (doCheck = false upstream), so short-circuit them.
        (_final: prev: {
          notmuch = prev.notmuch.overrideAttrs (
            old:
            prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
              postPatch = old.postPatch + ''
                substituteInPlace configure \
                  --replace-fail 'if ''${test_cmdline} >/dev/null 2>&1 && ./minimal' 'if false'
              '';
            }
          );
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
      darwinModules = getModules ./nix/modules/darwin_modules;

      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = inputs.nixpkgs.lib.genAttrs supportedSystems;

      # deploy-rs's own lib.activate.nixos bakes in a `deploy-rs` binary built
      # from deploy-rs's own flake (its own, disjoint, stale nixpkgs pin), not
      # from our nixpkgs. cache.nixos.org never serves that exact derivation,
      # so every deploy compiles it from source. Override it with nixpkgs's
      # own (Hydra-cached) deploy-rs package, per upstream's documented fix:
      # https://github.com/serokell/deploy-rs/blob/6d3087eedff75a715b40c0e124ba15d2dd7bec28/README.md#L92-L116
      deployRsLib =
        system:
        let
          plainPkgs = import inputs.nixpkgs { inherit system; };
        in
        (import inputs.nixpkgs {
          inherit system;
          overlays = [
            inputs.deploy-rs.overlays.default
            (_final: super: {
              deploy-rs = {
                inherit (plainPkgs) deploy-rs;
                lib = super.deploy-rs.lib;
              };
            })
          ];
        }).deploy-rs.lib;

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
                      dotfiles-worktree = dotfilesWorktree;
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
          modules =
            darwinModules
            ++ [
              ./nix/hosts/${hostname}/configuration.nix
              inputs.home-manager.darwinModules.home-manager
              inputs.mac-app-util.darwinModules.default
              inputs.work-config.darwinModule
              inputs.sops-nix.darwinModules.sops
            ]
            ++ includeModules
            ++ [
              (
                {
                  nixpkgs.overlays = overlays;
                  users.users.${username}.home = "/Users/${username}";
                  system.primaryUser = username;
                  sops.defaultSopsFile = ./nix/secrets/secrets.yaml;
                  home-manager = {
                    useGlobalPkgs = true;
                    useUserPackages = true;
                    extraSpecialArgs = {
                      dotfiles-root = self.outPath;
                      dotfiles-worktree = dotfilesWorktree;
                      inherit inputs;
                    };
                    # Include desktop modules for cross-platform validation
                    # This allows desktop modules to reference programs.plasma without evaluation errors
                    sharedModules =
                      hmCoreModules
                      ++ [ nixCatsHomeModule ]
                      ++ [ inputs.mac-app-util.homeManagerModules.default ]
                      ++ [ inputs.work-config.homeManagerModule ]
                      ++ (
                        if isDesktop then
                          hmDesktopModules
                          ++ [
                            inputs.plasma-manager.homeModules.plasma-manager
                          ]
                        else
                          [ ]
                      );
                    users.${username} =
                      let
                        baseProfile = {
                          imports = [
                            profileConfig.homeModule
                          ]
                          ++ (if builtins.pathExists hostHomeConfig then [ hostHomeConfig ] else [ ]);
                        };
                        extraUserConfig = extraConfig.home-manager.users.${username} or { };
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

      checks = forAllSystems (
        system:
        let
          pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = overlays;
            config = { };
          };

          # Guards against ever committing a decrypted sops/git-crypt file.
          # git-crypt smudges files to plaintext in the working tree, so this
          # checks the staged INDEX BLOB (git show :path), not the file on
          # disk. The git-crypt check is gated on the clean filter actually
          # being configured: `nix flake check`'s sandbox re-inits git with
          # no filters and stages everything decrypted, so it would otherwise
          # fail every flake check.
          staysEncrypted = pkgs.writeShellApplication {
            name = "stays-encrypted";
            runtimeInputs = [
              pkgs.git
              pkgs.gnugrep
              pkgs.coreutils
            ];
            text = ''
              fail=0
              # git show's output is read into a real file, never piped
              # straight into a command that might exit early (grep -q,
              # head -c) — an early-exiting reader closes its end of a pipe,
              # which kills the writer with SIGPIPE and aborts the whole
              # script under pipefail. Files also avoid bash variables
              # truncating at embedded NUL bytes, which git-crypt's magic
              # header starts with.
              tmpfile=$(mktemp)
              trap 'rm -f "$tmpfile"' EXIT

              while IFS= read -r f; do
                [ -n "$f" ] || continue
                git show ":$f" > "$tmpfile" 2>/dev/null || true
                if ! grep -q 'ENC\[' "$tmpfile"; then
                  echo "ERROR: sops file not encrypted: $f" >&2
                  fail=1
                fi
              done < <(git ls-files -- 'nix/secrets/*.yaml' 'nix/hosts/cogsworth/keys/*.sops')

              if git config --get filter.git-crypt.clean >/dev/null 2>&1; then
                while IFS= read -r f; do
                  [ -n "$f" ] || continue
                  git show ":$f" > "$tmpfile" 2>/dev/null || true
                  magic=$(head -c 10 "$tmpfile" | od -An -tx1 | tr -d ' \n')
                  # \0GITCRYPT\0 == 00474954435259505400
                  if [ "$magic" != "00474954435259505400" ]; then
                    echo "ERROR: git-crypt file decrypted in index: $f" >&2
                    fail=1
                  fi
                done < <(git ls-files -- ':(attr:filter=git-crypt)')
              fi

              exit "$fail"
            '';
          };
        in
        {
          pre-commit-check =
            inputs.pre-commit-hooks.lib.${system}.run {
              src = ./.;
              hooks = {
                black.enable = true;
                nixfmt.enable = true;
                prettier = {
                  enable = true;
                  excludes = [ "flake.lock" ];
                };
                shellcheck.enable = true;
                shfmt.enable = true;
                stylua.enable = true;
                pkg_version = {
                  enable = false;
                  name = "pkg-version-bump";
                  entry = "bin/pre-commit-update-version";
                  files = "^nix/pkgs/.*?/default\.nix$";
                  language = "script";
                  pass_filenames = true;
                };
                gofmt = {
                  enable = true;
                  name = "gofumpt";
                  entry = "${pkgs.gofumpt}/bin/gofumpt -l -w";
                  types = [ "go" ];
                };
                # No built-in gitleaks hook at this pre-commit-hooks.nix pin,
                # so this is a custom local hook.
                gitleaks = {
                  enable = true;
                  name = "gitleaks";
                  entry = "${pkgs.gitleaks}/bin/gitleaks dir --no-banner --redact --exit-code 1 --config ${./.gitleaks.toml} .";
                  language = "system";
                  pass_filenames = false;
                };
                stays-encrypted = {
                  enable = true;
                  name = "stays-encrypted";
                  entry = "${staysEncrypted}/bin/stays-encrypted";
                  language = "system";
                  pass_filenames = false;
                };
              };
            }
            # this functions outputs two checks defined in `deploy-rs`'s flake,
            # `deploy-schema` and `deploy-activate`.
            #
            # https://github.com/serokell/deploy-rs/blob/aa07eb05537d4cd025e2310397a6adcedfe72c76/flake.nix#L128
            // builtins.mapAttrs (_: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib;

          pi-coding-agent = import ./nix/checks/pi-coding-agent.nix { inherit pkgs; };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};

          clojure-mcp-light =
            let
              src = pkgs.fetchFromGitHub {
                owner = "bhauman";
                repo = "clojure-mcp-light";
                rev = "v0.2.2";
                hash = "sha256-PzYQ6WBlApjGbiAy+FS7QC+Mriqr9Jq6d5cr0LZ2Unk=";
              };
              parinferish = pkgs.fetchurl {
                url = "https://repo.clojars.org/parinferish/parinferish/0.8.0/parinferish-0.8.0.jar";
                hash = "sha256-vMEwpv0kRgnL8oVzwyjUxnO3cg01sMCYJNZFCOn6PA4=";
              };
              cljfmt-jar = pkgs.fetchurl {
                url = "https://repo.clojars.org/dev/weavejester/cljfmt/0.15.5/cljfmt-0.15.5.jar";
                hash = "sha256-0I8a/MmTtwhco8PC7IhiGKJSx7zYIyqTNYa7WJcBYOQ=";
              };
              classpath = "${src}/src:${parinferish}:${cljfmt-jar}";
              mkTool =
                name: ns:
                pkgs.writeShellScriptBin name ''
                  exec ${pkgs.babashka}/bin/bb -cp "${classpath}" -m ${ns} "$@"
                '';
            in
            pkgs.symlinkJoin {
              name = "clojure-mcp-light-0.2.2";
              paths = [
                (mkTool "clj-nrepl-eval" "clojure-mcp-light.nrepl-eval")
                (mkTool "clj-paren-repair-claude-hook" "clojure-mcp-light.hook")
                (mkTool "clj-paren-repair" "clojure-mcp-light.paren-repair")
              ];
            };
        in
        let
          mcpConfig = inputs.mcp-servers-nix.lib.mkConfig pkgs {
            programs = {
              playwright = {
                enable = true;
                executable =
                  if pkgs.stdenv.isDarwin then
                    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                  else
                    "${pkgs.chromium}/bin/chromium";
                args = [
                  "--viewport-size"
                  "1080x1920"
                  "--sandbox"
                ];
              };
            };
            settings.servers = {
              chrome-devtools = {
                type = "stdio";
                command = "npx";
                args = [
                  "-y"
                  "chrome-devtools-mcp@latest"
                  "--browserUrl"
                  "http://127.0.0.1:9222"
                ];
              };
            };
          };
        in
        {
          default = pkgs.mkShell {
            shellHook = self.checks.${system}.pre-commit-check.shellHook + ''
              if [ -L ".mcp.json" ]; then unlink .mcp.json; fi
              ln -sf ${mcpConfig} .mcp.json
            '';
            buildInputs = self.checks.${system}.pre-commit-check.enabledPackages ++ [
              pkgs.qmk
              pkgs.teensy-loader-cli
              pkgs.go
              pkgs.gopls
              pkgs.gofumpt
              pkgs.nodejs_22
              clojure-mcp-light
            ];

            # Skip nix flake check in smart-test hook to speed up claude-code
            CLAUDE_SKIP_NIX_TESTS = "true";
          };

          # Dev shell for nix/pkgs/winnow: `nix develop .#winnow` then `pytest`,
          # `ruff check .`, `ruff format .` per its README. Not part of the
          # winnow package build (that stays doCheck = false there).
          winnow = pkgs.mkShell {
            buildInputs = [
              (pkgs.python3.withPackages (
                ps: with ps; [
                  pyside6
                  pillow
                  send2trash
                  pytest
                  pytest-qt
                  pytest-cov
                ]
              ))
              pkgs.ruff
            ];

            # pytest-qt needs to find Qt's platform plugins (conftest.py
            # defaults QT_QPA_PLATFORM to offscreen, which still needs
            # QT_PLUGIN_PATH to locate libqoffscreen); also lets `winnow`
            # run interactively via the cocoa/xcb plugin if invoked directly.
            QT_PLUGIN_PATH = "${pkgs.qt6.qtbase}/lib/qt-6/plugins";
          };
        }
      );

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
          fuji-transcode = pkgs.fuji-transcode;
          git-worktree-prompt = pkgs.git-worktree-prompt;
          helios = pkgs.helios;
          winnow = pkgs.winnow;

          # Ergodox EZ firmware
          ergodox-firmware = pkgs.callPackage ./keyboard { };
        }
        // (inputs.nixpkgs.lib.optionalAttrs pkgs.stdenv.isDarwin { })
      );

      apps = forAllSystems (
        system:
        let
          pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = overlays;
            config = { };
          };
        in
        {
          flash-ergodox = {
            type = "app";
            meta.description = "Flash Ergodox EZ firmware";
            program = toString (
              pkgs.writeShellScript "flash-ergodox" ''
                set -e
                echo "Building Ergodox EZ firmware..."
                ${pkgs.nix}/bin/nix build .#ergodox-firmware
                echo ""
                echo "Firmware built successfully!"
                echo ""
                echo "Put your keyboard in bootloader mode:"
                echo "  - Press the physical reset button on the Ergodox EZ, OR"
                echo "  - Press the QK_BOOT key (Layer + bottom-left corner)"
                echo ""
                read -p "Press Enter once the keyboard is in bootloader mode..."
                echo ""
                echo "Flashing firmware..."
                ${pkgs.teensy-loader-cli}/bin/teensy-loader-cli -mmcu=atmega32u4 -w result/ergodox_ez_base_kyleondy.hex -v
                echo ""
                echo "✓ Firmware flashed successfully!"
              ''
            );
          };
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
          # Email (notmuch/neomutt/mbsync) is only used on dino.
          extraConfig = {
            home-manager.users.kyle = {
              hmFoundry.terminal.email.enable = true;
            };
          };
        };
        tiger = mkNixosSystem {
          hostname = "tiger";
          profile = "desktop";
        };

        cogsworth =
          let
            profileConfig = profiles.kiosk;
          in
          inputs.nixos-raspberrypi.lib.nixosSystem {
            specialArgs = { inherit inputs; };
            modules =
              nixModules
              ++ [
                inputs.nixos-raspberrypi.nixosModules."raspberry-pi-5".base
                inputs.nixos-raspberrypi.nixosModules.sd-image
                ./nix/hosts/cogsworth/configuration.nix
                inputs.sops-nix.nixosModules.sops
                inputs.home-manager.nixosModules.home-manager
                inputs.cogsworth.nixosModules.default
              ]
              ++ [
                {
                  systemFoundry = {
                    deployment_target.enable = true;
                    users.kyle.enable = true;
                  };

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
                    sharedModules = hmCoreModules ++ [ nixCatsHomeModule ];
                    users.kyle = {
                      imports = [ profileConfig.homeModule ];
                      hmFoundry.dev.terraform.enable = inputs.nixpkgs.lib.mkForce false;
                    };
                  };
                }
              ];
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
        username = "kondy";
      };
      darwinConfigurations.trex = mkDarwinSystem {
        hostname = "trex";
        profile = "desktop";
        username = "kyle";
        includeModules = [
          ./nix/hosts/trex/root-ssh-config.nix
          inputs.determinate.darwinModules.default
        ];
        # Email (notmuch/neomutt/mbsync) is only used on trex, matching dino.
        extraConfig = {
          home-manager.users.kyle = {
            hmFoundry.terminal.email.enable = true;
          };
        };
      };

      homeConfigurations."kyle@work-wsl" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
        extraSpecialArgs = {
          dotfiles-root = self.outPath;
          dotfiles-worktree = dotfilesWorktree;
          inherit inputs;
        };
        modules =
          hmCoreModules
          ++ [ nixCatsHomeModule ]
          ++ [ inputs.work-config.homeManagerModule ]
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
        confirmTimeout = 300;
        nodes = {
          dino = {
            hostname = "dino";
            profiles.system = {
              sshUser = "svc.deploy";
              user = "root";
              path = (deployRsLib "x86_64-linux").activate.nixos self.nixosConfigurations.dino;
            };
          };
          cogsworth = {
            fastConnection = false; # WiFi connection - use longer timeouts
            hostname = "cogsworth";
            profiles.system = {
              sshUser = "svc.deploy";
              user = "root";
              path = (deployRsLib "aarch64-linux").activate.nixos self.nixosConfigurations.cogsworth;
            };
          };
          tiger = {
            hostname = "tiger";
            profiles.system = {
              sshUser = "svc.deploy";
              user = "root";
              path = (deployRsLib "x86_64-linux").activate.nixos self.nixosConfigurations.tiger;
            };
          };

        };
      };
    };
}
