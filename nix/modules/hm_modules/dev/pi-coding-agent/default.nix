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
