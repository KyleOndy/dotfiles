# Pi Coding Agent
# Installs the `pi` CLI for non-interactive dispatch by the `work-*`
# script family (see nix/pkgs/my-scripts/scripts/work-agent-run).
#
# No interactive config is managed here -- skills, prompts, and
# settings.json used to live alongside this module but were removed
# once pi became script-only. Set your own `~/.pi/agent/` contents if
# you want to use pi interactively.

{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.pi-coding-agent;
in
{
  options.hmFoundry.dev.pi-coding-agent = {
    enable = mkEnableOption "pi coding agent";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      llm-agents.pi
    ];
  };
}
