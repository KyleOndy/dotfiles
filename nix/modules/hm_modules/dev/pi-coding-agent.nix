# Pi Coding Agent Configuration
# Installs pi and symlinks config directory to ~/.pi/agent/
#
# Why mkOutOfStoreSymlink instead of the normal home.file ./pi approach:
# Pi's /reload command hot-swaps skills, prompts, extensions, and keybindings
# without restarting the process. Normal home.file copies go into the nix store
# as read-only paths — Pi can write to them during /reload but the writes land
# in a throwaway path and are gone on the next home-manager switch. With
# mkOutOfStoreSymlink the target is the live dotfiles working tree, so any file
# Pi creates (or we edit by hand) shows up in git immediately and survives
# rebuilds.
#
# What is NOT symlinked and why:
#   auth.json   — secrets, mode 0600, Pi chmods it; symlink would break that
#   sessions/   — runtime state, meaningless to version-control
#   git/        — cloned pi packages, treated like a local package cache
#   npm/        — project npm installs, same rationale
#   AGENTS.md   — intentionally omitted; each environment (personal/work)
#                 overlays its own private version
#
# The workflow: edit any config file during a Pi session, run /reload in Pi,
# the change is live. Commit when ready, exactly like any other dotfile.

{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.pi-coding-agent;
  mkSymlink = config.lib.file.mkOutOfStoreSymlink;
in
{
  options.hmFoundry.dev.pi-coding-agent = {
    enable = mkEnableOption "pi coding agent";

    sourceDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/src/kyleondy/dotfiles/main/nix/modules/hm_modules/dev/pi";
      description = "Absolute path to pi config source directory for direct symlinks";
    };
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      llm-agents.pi
    ];

    home.sessionVariables = {
      PI_TELEMETRY = "0";
      PI_SKIP_VERSION_CHECK = "1";
    };

    home.file = {
      ".pi/agent/settings.json".source = mkSymlink "${cfg.sourceDir}/settings.json";
      ".pi/agent/keybindings.json".source = mkSymlink "${cfg.sourceDir}/keybindings.json";
      ".pi/agent/skills/".source = mkSymlink "${cfg.sourceDir}/skills";
      ".pi/agent/prompts/".source = mkSymlink "${cfg.sourceDir}/prompts";
      ".pi/agent/extensions/".source = mkSymlink "${cfg.sourceDir}/extensions";
      ".pi/agent/themes/".source = mkSymlink "${cfg.sourceDir}/themes";
    };
  };
}
