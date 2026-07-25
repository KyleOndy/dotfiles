{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.java;
in
{
  options.hmFoundry.dev.java.enable = mkEnableOption "java development with Maven";

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      jdk
      maven
      # Common Java development tools
      jdt-language-server # Java LSP for editors
      google-java-format # Code formatter
    ];

    home.sessionVariables.JAVA_HOME = "${pkgs.jdk}";
  };
}
