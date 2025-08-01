{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.terminal.pass;
in
{
  options.hmFoundry.terminal.pass = {
    enable = mkEnableOption "Pass; the standard unix passowrd manager";
  };

  config = mkIf cfg.enable {
    programs.password-store = {
      enable = true;
      package = pkgs.pass.withExtensions (ext: [ ext.pass-otp ]);
      settings = {
        PASSWORD_STORE_DIR = "${config.home.homeDirectory}/.password-store";
      };
    };

    home.packages =
      with pkgs;
      [
        passff-host # firefox plugin host extension
      ]
      ++ optionals stdenv.isLinux [
        wl-clipboard # needed since upgrading
      ];
  };
}
