# Ollama - local LLM server
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.ollama;
in
{
  options.hmFoundry.dev.ollama = {
    enable = mkEnableOption "Ollama local LLM server";

    service = {
      enable = mkEnableOption "Ollama background service (macOS only)";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ pkgs.master.ollama ];

    launchd.agents.ollama = mkIf (pkgs.stdenv.isDarwin && cfg.service.enable) {
      enable = true;
      config = {
        Label = "org.ollama.server";
        ProgramArguments = [
          "${pkgs.ollama}/bin/ollama"
          "serve"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${config.home.homeDirectory}/.ollama/service.stdout.log";
        StandardErrorPath = "${config.home.homeDirectory}/.ollama/service.stderr.log";
        EnvironmentVariables = {
          PATH = "${config.home.profileDirectory}/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        };
      };
    };
  };
}
