{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.go;
in
{
  options.hmFoundry.dev.go = {
    enable = mkEnableOption "golang development tools";

    installGo = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to install Go itself. Set to false to use system/Homebrew Go.";
    };
  };

  config = mkIf cfg.enable {
    programs.go = mkIf cfg.installGo {
      enable = true;
      package = pkgs.go;
    };

    home.packages = with pkgs; [
      golangci-lint
      ko
    ];
  };
}
