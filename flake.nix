{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-master.url = "github:nixos/nixpkgs/master";
    claude-code-nix = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # forge's guest VM. nixos-lima supplies the guest module that makes a NixOS
    # image driveable by lima at all: lima installs its guest agent by copying a
    # binary in and writing a unit, which a read-only /nix/store cannot accept.
    # Only nixosModules.lima is used, not the repo's own lima.nix, whose
    # stateVersion tracks a nixpkgs release ahead of ours. The image itself comes
    # from nixpkgs, which absorbed nixos-generators in 25.05.
    nixos-lima = {
      url = "github:nixos-lima/nixos-lima";
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
    nur = {
      url = "github:nix-community/NUR";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs.url = "github:serokell/deploy-rs";
    nixCats = {
      url = "github:BirdeeHub/nixCats-nvim";
    };
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
    claude-skills-ponytail = {
      url = "github:DietrichGebert/ponytail";
      flake = false;
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
    };
    # pi footer extension showing provider usage/quota (Z.ai Coding Plan
    # on trex; inert on hosts without a supported provider). Loaded as a pi
    # package via the symlink in dev/pi-coding-agent/default.nix.
    pi-usage = {
      url = "github:imdlan/pi-usage";
      flake = false;
    };
    cogsworth = {
      url = "git+ssh://git@github.com/KyleOndy/cogsworth?ref=v3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Work-specific configuration. Default is a no-op stub.
    # Override on work machines with the work flake's directory, which is that
    # repo's nix/ subdirectory rather than its root:
    #   --override-input work-config path:/Users/kondy/work/nix
    work-config.url = "path:./nix/work-config-stub";
  };
  outputs =
    { self, ... }@inputs:
    let
      # Working-tree path captured from the DOTFILES_WORKTREE env var (set
      # by the Makefile via `git rev-parse --show-toplevel`). Used by
      # home-manager modules that want mkOutOfStoreSymlink to point at the
      # *worktree* being deployed from, not the store snapshot, not a
      # hardcoded path. Empty/null when the flake is evaluated in pure
      # mode or outside `make`; the consuming module throws with a clear
      # message in that case.
      dotfilesWorktree =
        let
          env = builtins.getEnv "DOTFILES_WORKTREE";
        in
        if env != "" then env else null;

      # forge's docker host, as a disk image rather than a distro image plus an
      # `apt-get install docker.io` at boot: this way the guest's docker is the
      # version nixpkgs locks. Built for the linux system matching the darwin
      # host, which on a mac means the local linux-builder, so a change here
      # costs an image build rather than a substitution.
      forgeGuestImage =
        guestSystem:
        let
          image =
            (inputs.nixpkgs.lib.nixosSystem {
              modules = [
                { nixpkgs.hostPlatform = guestSystem; }
                inputs.nixos-lima.nixosModules.lima
                { _module.args.forgePorts = import ./nix/pkgs/forge/ports.nix; }
                ./nix/pkgs/forge/guest.nix
              ];
            }).config.system.build.images.qemu-efi;
        in
        # qemu-efi is qcow2 plus an EFI partition table, which vz boots directly.
        # passthru.filePath is the variant's own, so the name stays right if the
        # extension ever changes.
        "${image}/${image.passthru.filePath}";

      # forge only ever runs on the darwin hosts, but the overlay carrying it
      # has to evaluate everywhere, so map each host system to the linux one its
      # guest is built for.
      guestSystemFor = system: builtins.replaceStrings [ "darwin" ] [ "linux" ] system;

      # import all the overlays that extend packages via nix or home-manager.
      #
      # inputs.cogsworth.overlays.default is deliberately absent. It is a
      # git+ssh input, so applying it here forced every host to fetch a
      # private repo just to evaluate. The overlay defines exactly one
      # attribute (`cogsworth`), consumed only by cogsworth's own
      # nixosModule, so it now lives beside that consumer in cogsworth's
      # extraModules. Keeping private inputs out of the shared path is what
      # lets a host build its own closures without carrying a GitHub key.
      overlays = [
        inputs.nur.overlays.default
        (import ./nix/pkgs)

        (final: prev: {
          forge = prev.forge.override {
            guestImage = forgeGuestImage (guestSystemFor final.stdenv.hostPlatform.system);
          };
        })

        (final: _prev: {
          master = import inputs.nixpkgs-master {
            inherit (final.stdenv.hostPlatform) system;
            inherit (final) config;
          };
        })

        (final: _prev: {
          claude-code = inputs.claude-code-nix.packages.${final.stdenv.hostPlatform.system}.default;
        })

        # overlays.shared-nixpkgs builds llm-agents' npm packages against our
        # nixpkgs pin, which requires fetchNpmDeps fetcherVersion = 2
        # (nixpkgs >= 2026-02-15). We're pinned to nixos-25.11, which lacks
        # that backport, so build against llm-agents' own nixpkgs instead.
        # https://github.com/numtide/llm-agents.nix/issues/4320
        (final: _prev: {
          llm-agents = inputs.llm-agents.packages.${final.stdenv.hostPlatform.system};
        })

        # TODO: remove once direnv fixes fish test sandbox kills on macOS
        # direnv 2.37.1 fish tests get Killed: 9 in macOS sandbox during nix build
        (_final: prev: {
          direnv = prev.direnv.overrideAttrs (_old: {
            doCheck = false;
          });
        })

        # zsh-histdb loses history when several shells are open. Both bugs are
        # upstream at 90a6c10, the packaged revision, each with a fix that was
        # proposed and closed unmerged. af7c2ce moved writes to a per-shell
        # sqlite3 pipe without the `.timeout 1000` b20e9bb had added, so a
        # concurrent write is discarded rather than retried (issues 103, 143);
        # waiting is free off the prompt path. The outcome update takes the
        # newest row across every session rather than this one, so an
        # interleaved shell steals it (issue 45, PR 46).
        (_final: prev: {
          zsh-histdb = prev.zsh-histdb.overrideAttrs (old: {
            postPatch = ''
              substituteInPlace sqlite-history.zsh \
                --replace-fail \
                  'sqlite3 -batch -noheader "''${HISTDB_FILE}" < $PIPE' \
                  'sqlite3 -batch -noheader -cmd ".timeout 5000" "''${HISTDB_FILE}" < $PIPE' \
                --replace-fail \
                  'where id = (select max(id) from history) and' \
                  'where id = (select max(id) from history where session = ''${HISTDB_SESSION}) and'
            ''
            + old.postPatch;
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

      # tiger and cogsworth share every part of this except the nixosSystem
      # builder, the extra modules the Pi needs, and their home profile.
      # cogsworth used to carry its own copy of the block and drifted: it
      # silently lost dotfiles-worktree from extraSpecialArgs.
      mkLinuxSystem =
        {
          hostname,
          builder,
          extraModules ? [ ],
          homeModule,
          homeConfig ? { },
        }:
        builder {
          specialArgs = {
            inherit inputs;
          };
          modules =
            nixModules
            ++ [
              ./nix/hosts/${hostname}/configuration.nix
              inputs.sops-nix.nixosModules.sops
              inputs.home-manager.nixosModules.home-manager
            ]
            ++ extraModules
            ++ [
              {
                systemFoundry = {
                  deployment_target.enable = true;
                  users.kyle.enable = true;
                };

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
                  sharedModules = hmCoreModules ++ [ nixCatsHomeModule ];
                  users.kyle = {
                    imports = [ homeModule ];
                  }
                  // homeConfig;
                };
              }
            ];
        };

      # Helper function to create darwinSystem configurations
      mkDarwinSystem =
        {
          hostname,
          system ? "aarch64-darwin",
          includeModules ? [ ],
          username ? "kyle.ondy",
          extraConfig ? { },
        }:
        let
          hostHomeConfig = ./nix/hosts/${hostname}/home.nix;
        in
        inputs.nix-darwin.lib.darwinSystem {
          inherit system;
          modules =
            darwinModules
            ++ [
              ./nix/hosts/${hostname}/configuration.nix
              inputs.home-manager.darwinModules.home-manager
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
                    sharedModules =
                      hmCoreModules
                      ++ [ nixCatsHomeModule ]
                      ++ [ inputs.work-config.homeManagerModule ]
                      ++ hmDesktopModules
                      ++ [
                        # Spotlight does not index symlinks into the store,
                        # which is what linkApps (the default below
                        # stateVersion 25.11) leaves in ~/Applications.
                        {
                          targets.darwin.copyApps.enable = true;
                          targets.darwin.linkApps.enable = false;
                        }
                      ];
                    users.${username} =
                      let
                        baseProfile = {
                          imports = [
                            ./nix/profiles/desktop.nix
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
              # head -c). An early-exiting reader closes its end of a pipe,
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

          # The skills feed both Claude Code and pi. Claude Code's frontmatter
          # parser tolerates YAML that pi's rejects outright (an unquoted
          # description containing ": " is the case that bit us), and pi
          # silently drops a skill whose description is missing, so validate
          # against the stricter of the two before the file ships.
          skillFrontmatter = pkgs.writeShellApplication {
            name = "skill-frontmatter";
            runtimeInputs = [
              pkgs.yq-go
              pkgs.gnugrep
              pkgs.coreutils
              pkgs.gawk
            ];
            text = ''
              fail=0
              for f in "$@"; do
                if [ "$(head -n1 "$f")" != "---" ]; then
                  echo "ERROR: $f: no YAML frontmatter (line 1 is not ---)" >&2
                  fail=1
                  continue
                fi
                fm=$(awk 'NR>1 { if ($0 == "---") exit; print }' "$f")

                if ! err=$(printf '%s\n' "$fm" | yq -e '.' - 2>&1 >/dev/null); then
                  # yq prefixes stdin failures with "bad file '-'", which reads
                  # as a missing file rather than a parse error.
                  case $err in *"yaml:"*) err="yaml:''${err#*yaml:}" ;; esac
                  echo "ERROR: $f: frontmatter is not valid YAML" >&2
                  echo "  $err" >&2
                  fail=1
                  continue
                fi

                name=$(printf '%s\n' "$fm" | yq -r '.name // ""' -)
                desc=$(printf '%s\n' "$fm" | yq -r '.description // ""' -)

                if [ -z "$name" ]; then
                  echo "ERROR: $f: frontmatter has no name" >&2
                  fail=1
                elif ! printf '%s' "$name" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$'; then
                  echo "ERROR: $f: name '$name' is not lowercase a-z0-9 with single hyphens" >&2
                  fail=1
                fi

                if [ -z "$desc" ]; then
                  echo "ERROR: $f: frontmatter has no description" >&2
                  fail=1
                fi
              done

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
                skill-frontmatter = {
                  enable = true;
                  name = "skill-frontmatter";
                  entry = "${skillFrontmatter}/bin/skill-frontmatter";
                  language = "system";
                  files = "^nix/modules/hm_modules/dev/claude-code/skills/.*\\.md$";
                };
              };
            }
            # this functions outputs two checks defined in `deploy-rs`'s flake,
            # `deploy-schema` and `deploy-activate`.
            #
            # https://github.com/serokell/deploy-rs/blob/aa07eb05537d4cd025e2310397a6adcedfe72c76/flake.nix#L128
            // builtins.mapAttrs (_: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib;

          pi-coding-agent = import ./nix/checks/pi-coding-agent.nix { inherit pkgs; };
          forge-vm = import ./nix/checks/forge-vm.nix { inherit pkgs; };
          pi-broker = import ./nix/checks/pi-broker.nix { inherit pkgs; };
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

              # pkgs.qmk is a Python application, so the Python setup hook puts
              # its whole dependency closure on PYTHONPATH: 33 site-packages
              # directories belonging to one specific interpreter. Those shadow
              # every venv entered under this tree, and a venv on another minor
              # version then imports native extensions built for the wrong ABI
              # (`No module named 'rpds.rpds'`). The qmk launcher resolves its
              # own imports and does not read this.
              unset PYTHONPATH
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
          audio-language-check = pkgs.audio-language-check;
          forge = pkgs.forge;
          fuji-transcode = pkgs.fuji-transcode;
          git-worktree-prompt = pkgs.git-worktree-prompt;
          helios = pkgs.helios;
          winnow = pkgs.winnow;

          # Two-key push-to-talk pad for domestique rides
          pad-firmware = pkgs.callPackage ./keyboard/domestique-pad { };
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # keyboard/ergodox/default.nix:73 sets meta.platforms =
          # platforms.linux for the avr toolchain, so nixpkgs refuses to
          # evaluate this derivation on darwin. Offered only where it builds:
          # in the darwin `packages` set it took `nix flake check` down before
          # it reached any other output. pad-firmware carries darwin in its own
          # meta.platforms and needs no such gate.
          ergodox-firmware = pkgs.callPackage ./keyboard/ergodox { };
        }
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

          flash-pad = {
            type = "app";
            meta.description = "Flash the domestique push-to-talk pad";
            program = toString (
              pkgs.writeShellScript "flash-pad" ''
                set -euo pipefail
                readonly VOLUME=/Volumes/RPI-RP2

                echo "Building pad firmware..."
                ${pkgs.nix}/bin/nix build .#pad-firmware
                echo ""
                echo "Hold key 1 and plug the pad in."
                echo "  First flash ever: hold the board's BOOT button instead;"
                echo "  BOOTMAGIC only exists once QMK is on it."
                echo ""

                printf 'waiting for RPI-RP2 '
                waited=0
                while [ ! -d "$VOLUME" ] && [ "$waited" -lt 120 ]; do
                  printf '.'
                  sleep 0.5
                  waited=$((waited + 1))
                done
                echo ""

                if [ ! -d "$VOLUME" ]; then
                  echo "Timed out: $VOLUME never appeared." >&2
                  echo "The pad enumerates as a keyboard unless it is in the" >&2
                  echo "bootloader, so this means the key or button was missed." >&2
                  exit 1
                fi

                echo "Copying firmware..."
                # RP2040 reboots the instant the uf2 lands, so the volume can
                # vanish out from under cp. That is what success looks like.
                cp result/domestique_pad_default.uf2 "$VOLUME/" 2>/dev/null || true
                echo ""
                echo "Done. The pad reboots into firmware on its own."
              ''
            );
          };
        }
      );

      nixosConfigurations = {
        tiger = mkLinuxSystem {
          hostname = "tiger";
          builder = args: inputs.nixpkgs.lib.nixosSystem (args // { system = "x86_64-linux"; });
          homeModule = ./nix/profiles/server.nix;
        };

        # The backup host. Same builder line as tiger: plain x86_64, no device
        # tree, no sd-image, no vendor kernel.
        pika = mkLinuxSystem {
          hostname = "pika";
          builder = args: inputs.nixpkgs.lib.nixosSystem (args // { system = "x86_64-linux"; });
          homeModule = ./nix/profiles/appliance.nix;
        };

        # Install media, not a host. Deliberately outside mkLinuxSystem: it
        # would pull in sops secrets pika-installer holds no key for, and a
        # home-manager profile an ephemeral image has no use for.
        pika-installer = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ ./nix/hosts/pika/installer.nix ];
        };

        cogsworth = mkLinuxSystem {
          hostname = "cogsworth";
          builder = inputs.nixos-raspberrypi.lib.nixosSystem;
          extraModules = [
            inputs.nixos-raspberrypi.nixosModules."raspberry-pi-5".base
            inputs.nixos-raspberrypi.nixosModules.sd-image
            inputs.cogsworth.nixosModules.default
            # The overlay that provides pkgs.cogsworth, scoped to the one host
            # whose module reads it. See the note on `overlays` above.
            { nixpkgs.overlays = [ inputs.cogsworth.overlays.default ]; }
          ];
          homeModule = ./nix/profiles/kiosk.nix;
          homeConfig.hmFoundry.dev.terraform.enable = inputs.nixpkgs.lib.mkForce false;
        };
      };
      darwinConfigurations.work-mac = mkDarwinSystem {
        hostname = "work-mac";
        username = "kondy";
      };
      darwinConfigurations.trex = mkDarwinSystem {
        hostname = "trex";
        username = "kyle";
        includeModules = [
          ./nix/hosts/trex/root-ssh-config.nix
          inputs.determinate.darwinModules.default
        ];
        # Email (notmuch/neomutt/mbsync) is only used on trex.
        extraConfig = {
          home-manager.users.kyle = {
            hmFoundry.terminal.email.enable = true;
          };
        };
      };

      # deploy-rs
      deploy = {
        fastConnection = true;
        confirmTimeout = 300;
        nodes = {
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
          pika = {
            hostname = "pika";
            profiles.system = {
              sshUser = "svc.deploy";
              user = "root";
              path = (deployRsLib "x86_64-linux").activate.nixos self.nixosConfigurations.pika;
            };
          };

        };
      };
    };
}
