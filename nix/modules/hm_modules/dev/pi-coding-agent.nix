# Pi Coding Agent Configuration
# Installs pi and symlinks config directory to ~/.pi/agent/
#
# Uses mkOutOfStoreSymlink so config files are writable, letting pi
# edit its own skills/prompts directly in the dotfiles source.

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

    # Symlink pi config directly to dotfiles source (writable).
    # Pi can edit its own skills and prompts mid-session,
    # and changes land in the git-tracked source immediately.
    # AGENTS.md is intentionally omitted — set per-environment (work-config
    # provides a private version with internal references).
    home.file = {
      ".pi/agent/settings.json".source = mkSymlink "${cfg.sourceDir}/settings.json";
      ".pi/agent/skills/".source = mkSymlink "${cfg.sourceDir}/skills";
      ".pi/agent/prompts/".source = mkSymlink "${cfg.sourceDir}/prompts";
    };
  };
}
