# pi.dev coding agent with optional OS-level sandboxing.
#
# Sandbox wrapper flags (prepend before pi args):
#   --allow HOST           add domain to network allowlist (repeatable)
#   --allow-write PATH     add extra FS write path (repeatable)
#   --allow-read PATH      add extra FS read path (repeatable)
#   --web                  write+read confined to CWD/~.pi, network unrestricted
#   --no-sandbox           bypass sandbox entirely (with warning)
#
# Strict mode uses pkgs.llm-agents.sandbox-runtime (srt) on both platforms:
# bwrap on Linux, sandbox-exec on macOS; proxy-based network allowlist.
# Both network AND filesystem reads are default-deny: the allowlist starts
# empty, and reads are denied across all of $HOME except CWD, ~/.pi, and
# sandbox.allowedReadPaths / --allow-read. System paths (/nix, /etc) stay
# readable. Add toolchain read paths (~/.gitconfig, ~/.cargo, ...) as needed.
#
# Hardening defaults applied in every mode (see wrapper.sh), all overridable
# via sandbox.envVars:
#   - git: commit/tag signing off, core.hooksPath=/dev/null, fsmonitor/sshCommand
#     off (a hostile repo's hooks/config can't run code under the agent's git).
#     denyWrite also traps $PWD/.git/{hooks,config} + .gitmodules in strict mode.
#   - supply chain: npm/yarn lifecycle scripts blocked (npm_config_ignore_scripts);
#     NODE_OPTIONS stripped of code-injection flags (--require/--import/...).
#   - secrets: env vars whose names look secret-bearing (*_TOKEN/_SECRET/...) are
#     scrubbed unless injected via envFromCommands/envVars or a known provider key.
#   - caches: GOCACHE/CARGO_HOME/npm_config_cache/... redirected under
#     ~/.pi/sandbox-cache so default-deny FS doesn't break compilers (cold caches
#     are the tradeoff; for warm caches add the real dir to allowed{Read,Write}Paths).
#
# Web mode (no domain restriction) bypasses srt — srt forbids wildcard domains.
# Linux: bwrap directly (FS isolation, no --unshare-net).
# macOS: sandbox-exec FS profile (network unrestricted).
#
# Wrapper implementation lives in nix/pkgs/pi-wrapper so it can be reused by
# the flake check at nix/checks/pi-coding-agent.nix.
#
# Extension sources at nix/modules/hm_modules/dev/pi/ are symlinked via
# mkOutOfStoreSymlink into ~/.pi/agent/, not copied into the nix store. Pi's
# /reload hot-swaps extensions/skills/keybindings at runtime, and any file
# pi writes round-trips back into git. sourceDir defaults to the worktree
# you ran `make` from — see DOTFILES_WORKTREE in Makefile and the
# dotfilesWorktree binding in flake.nix. Each worktree symlinks to its own
# tree, so branch-based edits surface immediately without colliding.
{
  lib,
  pkgs,
  config,
  dotfiles-worktree,
  ...
}:
let
  cfg = config.hmFoundry.dev.pi-coding-agent;

  piPackage =
    if cfg.sandbox.enable then
      pkgs.pi-wrapper.override {
        defaultDomains = cfg.sandbox.allowedDomains;
        defaultWritePaths = cfg.sandbox.allowedWritePaths;
        defaultReadPaths = cfg.sandbox.allowedReadPaths;
        envFromCommands = cfg.sandbox.envFromCommands;
        defaultPiArgs = cfg.sandbox.defaultArgs;
        defaultEnvVars = cfg.sandbox.envVars;
        defaultAllowLoopback = cfg.sandbox.allowLocalBinding;
        defaultAllowTrustd = cfg.sandbox.allowTrustd;
        networkBundles = cfg.sandbox.networkBundles;
        gitAuthorName = cfg.sandbox.gitIdentity.name;
        gitAuthorEmail = cfg.sandbox.gitIdentity.email;
      }
    else
      pkgs.llm-agents.pi;

  defaultSourceDir =
    if dotfiles-worktree != null then
      "${dotfiles-worktree}/nix/modules/hm_modules/dev/pi"
    else
      throw ''
        hmFoundry.dev.pi-coding-agent: cannot resolve sourceDir.
        DOTFILES_WORKTREE is unset (or the flake is being evaluated in
        pure mode). Build via the Makefile targets (which export it and
        pass --impure), or set
        `hmFoundry.dev.pi-coding-agent.sourceDir` explicitly.
      '';
in
{
  options.hmFoundry.dev.pi-coding-agent = {
    enable = lib.mkEnableOption "pi coding agent";

    sourceDir = lib.mkOption {
      type = lib.types.str;
      default = defaultSourceDir;
      defaultText = lib.literalExpression "\${dotfiles-worktree}/nix/modules/hm_modules/dev/pi";
      description = ''
        Absolute path in the dotfiles working tree containing pi's
        symlinked config (extensions/, etc.). mkOutOfStoreSymlink points
        ~/.pi/agent/extensions at <sourceDir>/extensions so /reload picks
        up edits without a home-manager rebuild. Defaults to the worktree
        captured at make-time via DOTFILES_WORKTREE; override per-host if
        you need a different path.
      '';
    };

    sandbox = {
      enable = lib.mkEnableOption "sandbox pi via OS-level primitives" // {
        default = true;
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
          Base network allowlist. Empty by default — each host configures exactly
          the provider endpoints pi needs. Runtime --allow extends this.
          srt passes these through its filtering proxy; programs not respecting
          HTTP_PROXY/HTTPS_PROXY can bypass the filter.
        '';
      };

      allowedWritePaths = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = ''
          Extra filesystem write paths beyond CWD and ~/.pi.
          Supports ~ expansion. Runtime --allow-write extends this.
        '';
      };

      allowedReadPaths = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [
          "~/.gitconfig"
          "~/.config/git"
          "~/.cargo"
          "~/.rustup"
          "~/go"
        ];
        description = ''
          Extra filesystem READ paths beyond CWD and ~/.pi.

          Strict mode (the default) is default-deny on reads: srt denies all of
          $HOME and re-allows only CWD, ~/.pi, and these paths. That hides every
          credential store under $HOME (~/.ssh, ~/.aws, ~/.config/gh, ~/Library,
          ...) by construction, instead of relying on the credentialMasks
          deny-list to enumerate them. Reads outside $HOME (/nix, /etc, system
          toolchains) stay allowed so language tooling keeps working.

          The tradeoff is friction: any toolchain the agent invokes that reads
          config/caches under $HOME (git ~/.gitconfig, cargo ~/.cargo, rustup
          ~/.rustup, go ~/go, npm ~/.npmrc, ...) needs its path listed here, or
          its cache redirected into CWD via sandbox.envVars (GOCACHE/etc.). Add
          the toolchain dirs you actually use. Supports ~ expansion. Runtime
          --allow-read extends this per-invocation.

          Note: re-allowing ~/.pi also re-allows ~/.pi/agent/auth.json. Prefer
          envFromCommands for pi's provider key so it never sits readable on disk.
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
          flags — pi takes the last occurrence of --model, --provider, etc.
        '';
      };

      envVars = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = { };
        example = {
          GOCACHE = "$PWD/.gocache";
          GOMODCACHE = "$PWD/.gomodcache";
        };
        description = ''
          Static env vars exported into pi's environment by the wrapper
          before sandbox dispatch. Values are bash double-quote-expanded at
          runtime, so $PWD / $HOME resolve to the user's CWD-at-invocation
          and home directory.

          Use this to redirect tool caches (Go, Rust, npm) into CWD-relative
          paths the sandbox's allowWrite already covers, instead of
          broadening allowWrite to $HOME/Library/Caches/* directories.

          Distinct from envFromCommands: envVars are literal strings (only
          bash double-quote expansion runs); envFromCommands resolves a
          command's stdout. Use envFromCommands for secrets, envVars for
          plain config.
        '';
      };

      allowLocalBinding = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Permit TCP/UDP bind() and listen() on 127.0.0.1 / ::1 inside the
          strict sandbox by setting srt's network.allowLocalBinding=true.
          Required for httptest.NewServer, local dev servers (vite, air,
          rails s, etc.), and integration tests that stand up an in-process
          server.

          Does not open external network egress — srt's domain filter still
          applies, only loopback addresses are unblocked. Runtime
          --allow-loopback extends this per-invocation.
        '';
      };

      allowTrustd = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Default for srt's `enableWeakerNetworkIsolation`. When true (or
          when `--allow-trustd` is passed, or when an invoked bundle has
          `trustd = true`), srt's macOS sandbox profile permits
          `com.apple.trustd.agent` mach lookups so Go on macOS can verify
          TLS certificates through Security framework.

          Trade-off: trustd reachability is a known data-exfiltration
          vector (LDAP-over-trustd, OCSP responder URLs reachable). Leave
          off globally and let `--allow-go` flip it per-invocation, or set
          true here if Go work dominates this host.
        '';
      };

      networkBundles = lib.mkOption {
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
                  Security framework for cert verification — Go is the
                  known case. Cargo, npm, pip honor their own CA env
                  vars and do NOT need this.
                '';
              };
            };
          });
        default = {
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
        };
        description = ''
          Named bundles enabling per-invocation `--allow-<name>` CLI flags
          that extend the strict-mode network allowlist and (optionally)
          flip security loosenings the language needs.

          attrsOf merging: setting
          `sandbox.networkBundles.go = { ... }` replaces only the go
          bundle. Override or extend per-host to add internal registries
          or mirrors. Unknown `--allow-<name>` at the CLI fails fast with
          the known-bundles list on stderr.

          Network + trustd only for v1. Pair with
          `sandbox.allowedWritePaths` and `sandbox.envVars` for FS / env
          knobs.
        '';
      };

      gitIdentity = {
        name = lib.mkOption {
          type = lib.types.str;
          default = "Kyle's Daemon";
          description = ''
            Name stamped on any git commit pi makes. Forwarded to the
            wrapper, which exports GIT_AUTHOR_NAME / GIT_COMMITTER_NAME in
            pi's process tree only — repo and global git config are never
            touched. Default is intentionally non-human so agent commits
            stand out in `git log`; override per-host if you want a
            different label. Signing is unconditionally disabled on agent
            commits (see wrapper.sh) — that's not a knob.
          '';
        };
        email = lib.mkOption {
          type = lib.types.str;
          default = "ai-daemon@noreply.ondy.org";
          description = ''
            Email paired with `gitIdentity.name`. Same scoping rules —
            exported into pi's process tree, never written to config.
          '';
        };
      };

      envFromCommands = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = { };
        example = {
          OPENROUTER_API_KEY = "security find-generic-password -s pi -a openrouter -w";
        };
        description = ''
          Env vars resolved by the wrapper outside the sandbox before pi
          execs. Each value is a shell command; its stdout (trailing newline
          stripped by command substitution) becomes the env var, exported
          into pi's environment.

          Use this to inject API keys from macOS Keychain, pass, sops, etc.,
          so pi's models.json can reference them via "!printenv VAR" without
          granting the sandbox read access to credential paths or network
          access to a secrets backend.

          Resolver failure (non-zero exit) aborts pi startup with a
          diagnostic on stderr. Resolvers are not cached — keep them cheap
          (Keychain lookups are sub-10ms; avoid kubectl-per-run).

          Note: macOS Keychain "Always Allow" entries are keyed to the
          caller binary path, which changes on every pi-wrapper rebuild, so
          a fresh allow-prompt fires once after each rebuild.
        '';
      };
    };

    modelsJson = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''
        {
          providers.local = {
            baseUrl = "http://127.0.0.1:8000/v1";
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
        Contents of ~/.pi/agent/models.json, rendered verbatim via
        builtins.toJSON. Empty by default (pi ships built-in providers;
        this option only exists to register additional ones — custom
        OpenAI-compatible endpoints such as a local mlx-openai-server,
        Ollama, vLLM, or a proxy).

        See pi's custom-provider docs:
        https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/custom-provider.md

        This option owns the whole file — home-manager overwrites
        ~/.pi/agent/models.json on every activation, so a manually edited
        file (e.g. providers added by hand before this option existed) will
        be clobbered. Fold any such providers into this option's value
        first.

        Select a configured model per-invocation with `pi --model
        <provider>/<model-id>`, or pin one host-wide via
        sandbox.defaultArgs.
      '';
    };

    settingsJson = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''
        {
          compaction = {
            enabled = true;
            reserveTokens = 16384;
            keepRecentTokens = 20000;
          };
        }
      '';
      description = ''
        Contents of ~/.pi/agent/settings.json, rendered verbatim via
        builtins.toJSON. Empty by default (pi's own defaults apply).

        Pi's context management (auto-compaction, /compact, branch
        summarization, session tree) is already native and doesn't need
        building — this option exists so its knobs (compaction.reserveTokens
        / keepRecentTokens, defaultProvider, defaultModel, ...) are
        reproducible across hosts instead of hand-edited. See pi's settings
        and compaction docs:
        https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/settings.md
        https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/compaction.md

        This option owns the whole file — home-manager overwrites
        ~/.pi/agent/settings.json on every activation, so hand edits don't
        survive a rebuild. Fold any such settings into this option's value
        first.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ piPackage ];

    home.sessionVariables = {
      PI_TELEMETRY = "0";
      PI_SKIP_VERSION_CHECK = "1";
    };

    home.file.".pi/agent/extensions".source =
      config.lib.file.mkOutOfStoreSymlink "${cfg.sourceDir}/extensions";

    home.file.".pi/agent/models.json" = lib.mkIf (cfg.modelsJson != { }) {
      text = builtins.toJSON cfg.modelsJson;
    };

    home.file.".pi/agent/settings.json" = lib.mkIf (cfg.settingsJson != { }) {
      text = builtins.toJSON cfg.settingsJson;
    };
  };
}
