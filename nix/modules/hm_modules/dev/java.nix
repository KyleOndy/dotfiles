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
  options.hmFoundry.dev.java = {
    enable = mkEnableOption "java development with Maven";

    jdkVersion = mkOption {
      type = types.enum [
        "8"
        "11"
        "17"
        "21"
        "latest"
      ];
      default = "latest";
      description = "JDK version to install (8, 11, 17, 21, or latest)";
    };
  };

  config = mkIf cfg.enable {
    home.packages =
      with pkgs;
      let
        selectedJdk =
          {
            "8" = jdk8;
            "11" = jdk11;
            "17" = jdk17;
            "21" = jdk21;
            "latest" = jdk;
          }
          .${cfg.jdkVersion};
      in
      [
        selectedJdk
        maven
        # Common Java development tools
        jdt-language-server # Java LSP for editors
        google-java-format # Code formatter
      ];

    home.sessionVariables = {
      JAVA_HOME = "${
        {
          "8" = pkgs.jdk8;
          "11" = pkgs.jdk11;
          "17" = pkgs.jdk17;
          "21" = pkgs.jdk21;
          "latest" = pkgs.jdk;
        }
        .${cfg.jdkVersion}
      }";
    };
  };
}
