# pi.dev coding agent with optional OS-level sandboxing.
#
# Sandbox wrapper flags (prepend before pi args):
#   --allow HOST           add domain to network allowlist (repeatable)
#   --allow-write PATH     add extra FS write path (repeatable)
#   --web                  FS isolation only, no network restriction
#   --no-sandbox           bypass sandbox entirely (with warning)
#
# Strict mode uses pkgs.llm-agents.sandbox-runtime (srt) on both platforms:
# bwrap on Linux, sandbox-exec on macOS; proxy-based network allowlist.
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
        envFromCommands = cfg.sandbox.envFromCommands;
        defaultPiArgs = cfg.sandbox.defaultArgs;
        defaultEnvVars = cfg.sandbox.envVars;
        defaultAllowLoopback = cfg.sandbox.allowLocalBinding;
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
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ piPackage ];

    home.sessionVariables = {
      PI_TELEMETRY = "0";
      PI_SKIP_VERSION_CHECK = "1";
    };

    home.file.".pi/agent/extensions".source =
      config.lib.file.mkOutOfStoreSymlink "${cfg.sourceDir}/extensions";
  };
}
