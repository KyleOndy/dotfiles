# Installs pi.dev coding agent with telemetry disabled.
# Config intentionally left at upstream defaults; pi writes its own state
# under ~/.pi/agent/ at runtime.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.hmFoundry.dev.pi-coding-agent;
in
{
  options.hmFoundry.dev.pi-coding-agent = {
    enable = lib.mkEnableOption "pi coding agent";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.llm-agents.pi ];

    home.sessionVariables = {
      PI_TELEMETRY = "0";
      PI_SKIP_VERSION_CHECK = "1";
    };
  };
}
