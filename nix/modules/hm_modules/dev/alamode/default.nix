# alamode: private sessions with immutable runtime configuration and a
# credential relay, wrapping the upstream pi coding agent.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.hmFoundry.dev.alamode;

  alamodePackage =
    if cfg.sandbox.enable then
      pkgs.alamode.override {
        defaultDomains = cfg.sandbox.allowedDomains;
        defaultEnvVars = cfg.sandbox.envVars;
        defaultPiArgs = cfg.sandbox.defaultArgs;
        defaultListenPorts = cfg.sandbox.listenPorts;
        defaultReadPaths = cfg.sandbox.allowedReadPaths;
        defaultWritePaths = cfg.sandbox.allowedWritePaths;
        defaultGitWrite = cfg.sandbox.gitWrite;
        builder = lib.optionalString (cfg.sandbox.builderConfig != null) cfg.sandbox.builderConfig;
        nixDaemonSocket = lib.optionalString (cfg.sandbox.nixDaemon != null) cfg.sandbox.nixDaemon.socket;
        nixDaemonLabel = lib.optionalString (cfg.sandbox.nixDaemon != null) cfg.sandbox.nixDaemon.label;
        nixClient = if cfg.sandbox.nixDaemon != null then pkgs.alamode-nix-client else null;
        bundles = cfg.sandbox.bundles;
        profiles = cfg.sandbox.profiles;
        envFromCommands = cfg.sandbox.envFromCommands;
        envGrantGates = cfg.sandbox.envGrantGates;
        gitAuthorName = cfg.sandbox.gitIdentity.name;
        gitAuthorEmail = cfg.sandbox.gitIdentity.email;
        seatsFile = lib.optionalString (cfg.seatsFile != null) cfg.seatsFile;
        settingsFile = "${settingsFile}";
        catalogFile =
          if cfg.modelsJsonFile != null then
            cfg.modelsJsonFile
          else if cfg.modelsJson != { } then
            toString (pkgs.writeText "alamode-models.json" (builtins.toJSON cfg.modelsJson))
          else
            "";
        runtimeSource = toString runtimeSource;
        privateProviderHosts = cfg.sandbox.privateProviderHosts;
        delegateBin = lib.getExe pkgs.alamode-delegate;
        bell = lib.getExe pkgs.notification-bell;
        seatsBin = lib.optionalString seatsEnabled (lib.getExe seatsPackage);
        sliceBin = lib.optionalString config.hmFoundry.terminal.tmux.enable (lib.getExe slicePackage);
        inherit (cfg) trustedProviders;
        coordinatorDaemon = lib.optionalString cfg.coordinator.enable (
          lib.getExe (
            pkgs.alamode-coordinator.override {
              inherit (cfg.coordinator) maxAgents maxRetainedAgents;
              withForge = cfg.coordinator.forge.enable;
              inherit (cfg.coordinator.forge) memoryBudgetGib;
            }
          )
        );
      }
    else
      pkgs.llm-agents.pi;

  # retry.maxRetries 6 against the default 2s base: pi's agent-level backoff
  # is baseDelayMs * 2^(attempt-1) with no jitter, each sleep capped at
  # retry.maxAgentDelayMs (60s), so the budget is 122s and the longest single
  # sleep is 60s. The default 3 gives up after 14s, which mcloud outranks on a
  # routine overload; past 6 every retry adds another silent minute that
  # reads as a hang, with nothing on screen to say the session is only
  # waiting. shellPath replaces macOS's
  # /bin/bash 3.2, which cannot parse `"$(cat <<'EOF'` with an apostrophe
  # in the heredoc body, the usual commit-message shape.
  settingsFile = pkgs.writeText "alamode-settings.json" (
    builtins.toJSON (lib.importJSON ./settings.json // { shellPath = lib.getExe pkgs.bashInteractive; })
  );

  seatsEnabled = cfg.seatsFile != null || cfg.trustedProviders != [ ];
  runtimeSource = pkgs.runCommand "alamode-runtime-config" { } ''
    cp -R ${
      builtins.path {
        path = /. + cfg.sourceDir;
        name = "alamode-runtime-source";
      }
    } "$out"
    chmod -R u+w "$out"
    # grants/nix.md describes the Tart builder; a host whose --allow-nix is the
    # session daemon gets nix-daemon.md under that name instead.
    ${
      if cfg.sandbox.nixDaemon != null then
        ''mv "$out/grants/nix-daemon.md" "$out/grants/nix.md"''
      else
        ''rm "$out/grants/nix-daemon.md"''
    }
    ${lib.concatMapStrings (skill: ''
      mkdir -p "$out/skills/${skill.name}"
      ${
        if skill.isFile then
          ''cp ${skill.source} "$out/skills/${skill.name}/SKILL.md"''
        else
          ''cp -R ${skill.source}/. "$out/skills/${skill.name}/"''
      }
    '') (config.lib.agentContext.skillsFor "alamode")}
  '';
  seatsPackage = pkgs.alamode-seats.override {
    seatsFile = lib.optionalString (cfg.seatsFile != null) cfg.seatsFile;
    inherit (cfg) trustedProviders;
    secretsSource = lib.optionalString (cfg.secretsSource != null) cfg.secretsSource;
    relayModule = "${pkgs.alamode-relay}/libexec/alamode-relay/relay.py";
    inherit (cfg.sandbox) privateProviderHosts;
  };
  # tmux-sessionizer comes from PATH, so sliceBin is set only where the tmux
  # module installs it.
  slicePackage = pkgs.writeShellApplication {
    name = "alamode-slice";
    runtimeInputs = [
      pkgs.direnv
      pkgs.my-scripts
    ];
    text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./slice.sh);
  };

  defaultSourceDir = toString ../alamode/source;

  profileBundleViolations = lib.concatMap (
    name:
    map (bundle: "${name}: ${bundle}") (
      lib.subtractLists (lib.attrNames cfg.sandbox.bundles) (cfg.sandbox.profiles.${name}.bundles or [ ])
    )
  ) (lib.attrNames cfg.sandbox.profiles);
in
{
  options.hmFoundry.dev.alamode = {
    enable = lib.mkEnableOption "alamode";

    sourceDir = lib.mkOption {
      type = lib.types.str;
      default = defaultSourceDir;
      defaultText = lib.literalExpression "../alamode/source";
      description = ''
        Runtime configuration copied into the Nix store at build time.
        Sessions receive private settings and load extensions from this
        immutable source. Rebuild to deploy extension changes.
      '';
    };

    sandbox = {
      builderConfig = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Trusted native Darwin builder JSON file. --allow-nix exposes a
          scoped build service using this configuration. Keep it outside
          agent-writable paths. See nix/pkgs/alamode-builder/README.md.
        '';
      };
      nixDaemon = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              socket = lib.mkOption { type = lib.types.str; };
              label = lib.mkOption { type = lib.types.str; };
            };
          }
        );
        default = null;
        description = ''
          The session nix daemon (systemFoundry.alamodeNixDaemon): its socket
          and launchd label. --allow-nix gives the session that socket and a
          client for it, after canary builds show the daemon still refuses
          networked builds. See docs/alamode-host-nix.md.
        '';
      };
      privateProviderHosts = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Exact private or loopback provider hostnames the trusted inference relay may contact.";
      };
      enable = lib.mkEnableOption "sandbox pi via OS-level primitives" // {
        default = true;
      };

      envVars = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = { };
        example = {
          GOCACHE = "$PWD/.gocache";
          GOMODCACHE = "$PWD/.gomodcache";
        };
        description = ''
          Nonsecret environment values for the workload. Literal $HOME and
          $PWD expand to the private session home and workspace. No shell
          expansion runs. Credentials belong in envFromCommands.
        '';
      };

      envFromCommands = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = { };
        example = {
          OPENROUTER_API_KEY = "/usr/bin/security find-generic-password -s alamode -a openrouter -w";
        };
        description = ''
          Trusted host commands that resolve credentials for the provider
          and tool relays. Their output never enters the workload environment.
          The model catalog can reference these values through !printenv VAR.
          Commands run outside containment with the configured tool PATH;
          use absolute executable paths. Failure aborts session startup.
        '';
      };

      envGrantGates = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = { };
        example = {
          KAGI_API_KEY = "kagi";
        };
        description = ''
          Required bundle grant for each credential resolver.
          Ungranted values are neither resolved nor inherited from the host.
          Unknown grant names abort startup. Leave inference keys ungated.
        '';
      };

      allowedReadPaths = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [
          "~/.gitconfig"
          "/Users/me/private-config/files"
        ];
        description = ''
          Additional host paths readable in strict and web sessions. Paths
          resolve symlinks at admission; ~ expands to the human home.
          Runtime --allow-read and --allow-rw extend the list. Trusted
          session records and host service socket directories are rejected.
        '';
      };

      allowedWritePaths = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [ "~/.kube/configs" ];
        description = ''
          Additional host paths readable and writable by the workload.
          Runtime --allow-write and --allow-rw extend the list. Prefer the
          private session caches to granting shared host cache directories.
        '';
      };

      gitWrite = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Allow commits in private session Git storage. The human repository is never writable by default.";
      };

      listenPorts = lib.mkOption {
        type = with lib.types; listOf (ints.between 1 65535);
        default = [ ];
        example = [
          3000
          8080
        ];
        description = "Loopback ports sessions may bind and contact. --listen PORT adds a port at admission.";
      };

      allowedDomains = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [
          "openrouter.ai"
          "api.anthropic.com"
          "github.com"
        ];
        description = ''
          Workload network allowlist. Empty by default; inference uses a
          separate authenticated relay. Runtime --allow adds a destination.
          --web permits public web destinations through the same proxy and
          filesystem boundary.
        '';
      };

      bundles = lib.mkOption {
        type =
          with lib.types;
          attrsOf (submodule {
            options = {
              domains = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Network hosts added to the allowlist when this bundle is invoked.";
              };
              trustd = lib.mkOption {
                type = bool;
                default = false;
                description = ''
                  Whether this bundle requires `com.apple.trustd.agent`
                  access (srt's `enableWeakerNetworkIsolation` toggle).
                  Set true for languages whose HTTPS client uses macOS
                  Security framework for cert verification, Go is the
                  known case. Cargo, npm, pip and the JVM honor their own
                  CA stores and do NOT need this.
                '';
              };
              nix = lib.mkOption {
                type = bool;
                default = false;
                description = ''
                  Whether invoking this bundle also grants everything
                  `--allow-nix` does, for a bundle whose hosts only the nix
                  client fetches from.
                '';
              };
              readPaths = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = ''
                  Paths re-allowed for reading when this bundle is invoked,
                  on top of strict mode's default-deny from `/` down. A
                  leading `~` is expanded by the wrapper. For a toolchain's
                  config and package cache: `~/.m2`, `~/.clojure`.
                '';
              };
              writePaths = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = ''
                  Paths added to `allowWrite` when this bundle is invoked.
                  A package cache usually wants both this and `readPaths`,
                  since resolving a dependency it does not already hold
                  writes into it.
                '';
              };
            };
          });
        default = { };
        description = ''
          Named bundles enabling per-invocation `--allow-<name>` CLI flags
          that extend the strict-mode network allowlist and (optionally)
          flip security loosenings the language needs.

          The go / rust / node / python bundles are supplied by this
          module's own config rather than by this default, because the
          module system applies an option's default only when nothing
          defines the option at all. As a definition they merge with a
          host's, so adding `sandbox.bundles.linear` keeps the
          language bundles and setting `sandbox.bundles.go.domains`
          overrides that list while leaving `go.trustd` alone. Naming them
          in the default would instead have discarded all four the moment
          a host added a fifth.

          An unknown `--allow-<name>` at the CLI is refused before anything
          starts. A name the session uses for a built-in grant (`nix`,
          `forge`, `trustd`, `clipboard`, `read`, `write`, `rw`, `git-write`)
          is refused when the wrapper is built.

          A bundle also carries `readPaths` / `writePaths`, so a toolchain
          whose caches live under the denied `$HOME` is one flag rather than
          a flag plus two `--allow-read`s. Env stays out: the cache redirects
          in the wrapper's hardening list are unconditional, since pointing
          a cache somewhere writable costs nothing in a session that never
          runs that toolchain.
        '';
      };

      profiles = lib.mkOption {
        type =
          with lib.types;
          attrsOf (submodule {
            options = {
              domains = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Network hosts granted by this profile.";
              };
              readPaths = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Host paths granted readable by this profile.";
              };
              writePaths = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Host paths granted writable by this profile.";
              };
              listenPorts = lib.mkOption {
                type = listOf (ints.between 1 65535);
                default = [ ];
                description = "Loopback ports granted by this profile.";
              };
              trustd = lib.mkOption {
                type = bool;
                default = false;
                description = "Whether this profile permits Apple certificate validation services.";
              };
              nix = lib.mkOption {
                type = bool;
                default = false;
                description = "Whether this profile grants the isolated Nix builder.";
              };
              forge = lib.mkOption {
                type = bool;
                default = false;
                description = "Whether this profile authorizes optional Forge resources for children.";
              };
              bundles = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = ''
                  Names of sandbox.bundles granted by this profile. The
                  wrapper build refuses a profile naming an unknown bundle.
                '';
              };
            };
          });
        default = { };
        description = ''
          Named grant presets applied by `alamode --profile NAME`
          (repeatable, merged). A profile expands into the same fields the
          grant flags set, before grant recording, so resumes refuse drift
          exactly as they do for flags. Profiles never imply a verb:
          `alamode coord` stays explicit.
        '';
      };

      defaultArgs = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [
          "--model"
          "anthropic/claude-sonnet-4"
        ];
        description = ''
          Args prepended to every `pi` invocation, before any user-supplied
          args. Use this to pin a default model/provider so you don't have
          to type --model on every command. User args still win on repeated
          flags; pi takes the last occurrence of --model, --provider, etc.
        '';
      };

      gitIdentity = {
        name = lib.mkOption {
          type = lib.types.str;
          default = "Kyle's Daemon";
          description = ''
            Name stamped on any git commit pi makes. Forwarded to the
            wrapper, which exports GIT_AUTHOR_NAME / GIT_COMMITTER_NAME in
            pi's process tree only, repo and global git config are never
            touched. Default is intentionally non-human so agent commits
            stand out in `git log`; override per-host if you want a
            different label. Signing is unconditionally disabled on agent
            commits (see alamode-runtime/session.py), that's not a knob.
          '';
        };
        email = lib.mkOption {
          type = lib.types.str;
          default = "ai-daemon@noreply.ondy.org";
          description = ''
            Email paired with `gitIdentity.name`. Same scoping rules,
            exported into pi's process tree, never written to config.
          '';
        };
      };

    };

    coordinator = {
      enable = lib.mkEnableOption ''
        `alamode coord`, a persistent service with independently
        supervised RPC agents and private Git storage. Forge is optional.
      '';
      maxAgents = lib.mkOption {
        type = lib.types.ints.between 1 15;
        default = 8;
        description = "Agents running at once across every coordinator on the host.";
      };
      maxRetainedAgents = lib.mkOption {
        type = lib.types.ints.between 1 4096;
        default = 8 * cfg.coordinator.maxAgents;
        defaultText = lib.literalExpression "8 * coordinator.maxAgents";
        description = ''
          Retained child records per coordinator, including closed and failed
          children. Further spawns are refused without deleting preserved work.
        '';
      };
      forge = {
        enable = lib.mkEnableOption ''
          a forge VM for each spawned agent whose spawn names a size, held
          until the agent is torn down. Needs forge's configs in
          ~/.config/forge
        '';
        memoryBudgetGib = lib.mkOption {
          type = lib.types.ints.positive;
          default = 32;
          description = ''
            GiB of forge VM memory all agents may hold at once. small is
            4GiB, large 8GiB and xlarge 16GiB; a spawn past the budget is
            refused.
          '';
        };
      };
    };

    seatsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/alamode_seats";
      description = ''
        The host's seats: an env file of `PI_*_MODEL=provider/id[:level]`
        lines, one per model choice (session, advisor, each task agent,
        coordinator children, alamode-delegate, domestique's classifier), with
        comments saying what each is for. The ids are private, so the file is
        a sops secret and never a store path. Session admission records the
        configured seats. `alamode-seats check` validates the deployed catalog.
      '';
    };

    secretsSource = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "nix/secrets/trex.yaml";
      description = ''
        Repo path of the sops file holding this host's seats and catalog.
        Only ever printed: every refusal and failed seat check names it as
        the file to `sops edit`.
      '';
    };

    trustedProviders = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "mcloud" ];
      description = ''
        Providers a session may run on. With any listed, pi refuses to start
        on another, and task agents and the advisor refuse one too, so this
        host's model ids only ever reach these. Empty refuses nothing.
      '';
    };

    modelsJsonFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/alamode_models_json";
      description = ''
        Host-only model catalog, normally a sops secret. The trusted relay
        resolves credentials and creates a private catalog containing scoped
        relay tokens. The workload cannot read this source file.
        Exclusive with modelsJson.
      '';
    };

    modelsJson = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''
        {
          providers.local = {
            baseUrl = "http://127.0.0.1:8770/v1";
            api = "openai-completions";
            apiKey = "local-no-key";
            compat.supportsDeveloperRole = false;
            models = [
              {
                id = "qwen3-coder";
                name = "Qwen3 Coder (local, mlx)";
                reasoning = false;
                input = [ "text" ];
                cost = {
                  input = 0;
                  output = 0;
                  cacheRead = 0;
                  cacheWrite = 0;
                };
                contextWindow = 128000;
                maxTokens = 8192;
              }
            ];
          };
        }
      '';
      description = ''
        Public model catalog copied into the Nix store. Credentials must be
        references to trusted resolvers. Use modelsJsonFile for private model
        identifiers or endpoints. Each permitted model must be explicit.
        Supported APIs are openai-completions, openai-responses and
        anthropic-messages. Local providers require privateProviderHosts.

        Catalog format:
        https://github.com/earendil-works/pi/blob/a13d35a742c6ef8462812a28fbe1d8c8b7431c32/packages/coding-agent/docs/models.md

        Select a model with alamode -- --model provider/model, or configure a seat.
      '';
    };

  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.sandbox.builderConfig == null || cfg.sandbox.nixDaemon == null;
        message = "hmFoundry.dev.alamode: --allow-nix means one of sandbox.builderConfig and sandbox.nixDaemon, not both.";
      }
      {
        assertion = profileBundleViolations == [ ];
        message = "hmFoundry.dev.alamode: profiles name unknown bundles: ${toString profileBundleViolations}";
      }
      {
        assertion = cfg.modelsJson == { } || cfg.modelsJsonFile == null;
        message = "hmFoundry.dev.alamode: set modelsJson or modelsJsonFile, not both.";
      }
      {
        assertion = seatsEnabled -> cfg.sandbox.enable;
        message = "hmFoundry.dev.alamode: seatsFile and trustedProviders need sandbox.enable: the wrapper is what loads and enforces them.";
      }
      {
        assertion = cfg.coordinator.enable -> cfg.sandbox.enable;
        message = "hmFoundry.dev.alamode.coordinator needs sandbox.enable: the coordinator spawns children through the sandbox wrapper.";
      }
    ];

    # pi has no web tool, so search and page-reading are a CLI the
    # bash tool reaches. Both halves are Kagi endpoints, which is what lets
    # the kagi bundle below grant one domain instead of the wildcard egress
    # that reading arbitrary pages would otherwise need.
    home.packages = [
      alamodePackage
      pkgs.kagi
      pkgs.alamode-delegate
    ]
    ++ lib.optional seatsEnabled seatsPackage;

    home.sessionVariables = {
      PI_TELEMETRY = "0";
      PI_SKIP_VERSION_CHECK = "1";
    };

    # A definition, not the option's default, so a host adding its own bundle
    # merges with these four instead of replacing them. See the option's
    # description for why the distinction matters.
    hmFoundry.dev.alamode.sandbox.bundles =
      let
        # Maven Central under both names poms are written against.
        mavenDomains = [
          "repo1.maven.org"
          "repo.maven.apache.org"
        ];
        # Read and write: resolving a dependency the cache does not hold
        # writes it there, so read-only fails the first cold build.
        mavenPaths = [ "~/.m2" ];
      in
      {
        go = {
          domains = [
            "proxy.golang.org"
            "sum.golang.org"
          ];
          trustd = true;
        };
        rust = {
          domains = [
            "crates.io"
            "static.crates.io"
            "index.crates.io"
          ];
        };
        node = {
          domains = [ "registry.npmjs.org" ];
        };
        python = {
          domains = [
            "pypi.org"
            "files.pythonhosted.org"
          ];
        };
        # No trustd: the JVM verifies TLS against its own cacerts rather than
        # Security framework.
        java = {
          domains = mavenDomains;
          readPaths = mavenPaths;
          writePaths = mavenPaths;
        };
        # Self-sufficient rather than layered on java, because `clj` resolves
        # through maven itself and needing two flags to run one test suite is a
        # papercut that buys no isolation. ~/.clojure holds deps.edn and the
        # user-level .cpcache; ~/.gitlibs holds :git/sha deps, which cogsworth
        # has one of. github.com and codeload are what fetches those.
        clojure = {
          domains = mavenDomains ++ [
            "repo.clojars.org"
            "github.com"
            "codeload.github.com"
          ];
          readPaths = mavenPaths ++ [
            "~/.clojure"
            "~/.gitlibs"
          ];
          writePaths = mavenPaths ++ [
            "~/.clojure"
            "~/.gitlibs"
          ];
        };
        # Not a toolchain, but the same flag mechanism. Kagi's /extract
        # returns any page as markdown from kagi.com, so fetching one costs
        # the same single domain as searching and never needs the wildcard
        # egress srt refuses to express. Reaching a page directly would, which
        # is why `alamode --web` and not this bundle is what a raw curl needs.
        kagi = {
          domains = [ "kagi.com" ];
        };
        # Inputs fetch in the nix client, before anything reaches the daemon,
        # so --allow-nix alone still dies at the proxy on the first cold
        # input: gitlab.com carries NUR's rycee firefox-addons, github and
        # flakehub the rest of flake.lock. Substitution is daemon-side, which
        # --allow-nix already covers, so these five are everything eval
        # fetches, and no use without the daemon. Not named "nix": the
        # wrapper refuses a bundle named after one of the session's own
        # grants.
        flake = {
          domains = [
            "github.com"
            "codeload.github.com"
            "gitlab.com"
            "api.flakehub.com"
            "flakehub.com"
          ];
          nix = true;
        };
      };

    home.file = {
      ".pi/agent/extensions".source = "${runtimeSource}/extensions";
      ".pi/agent/agents".source = "${runtimeSource}/agents";
      ".pi/agent/themes".source = "${runtimeSource}/themes";
      ".pi/agent/grants".source = "${runtimeSource}/grants";
      ".pi/agent/keybindings.json".source = "${runtimeSource}/keybindings.json";
      ".pi/agent/AGENTS.md".source = lib.mkDefault "${runtimeSource}/AGENTS.md";

      ".pi/agent/models.json" = lib.mkMerge [
        (lib.mkIf (cfg.modelsJson != { }) { text = builtins.toJSON cfg.modelsJson; })
        (lib.mkIf (cfg.modelsJsonFile != null) {
          source = lib.mkDefault (config.lib.file.mkOutOfStoreSymlink cfg.modelsJsonFile);
        })
      ];
    }
    // config.lib.agentContext.skillFiles "alamode" ".pi/agent/skills";
  };
}
