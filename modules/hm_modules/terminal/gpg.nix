{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.terminal.gpg;
in
{
  options.hmFoundry.terminal.gpg = {
    enable = mkEnableOption "gpg";
    service = mkOption {
      type = types.bool;
      default = true;
    };
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      # todo: this should be covered by the programs block
      gnupg # for email and git
      pinentry-curses # cli pin entry
    ];
    home.sessionVariables =
      {
        GNUPGHOME = "$HOME/.gnupg";
      };

    programs.gpg = {
      enable = true;
      scdaemonSettings = {
        disable-ccid = true;
      };
    };

    services.gpg-agent = {
      enable = cfg.service;
      defaultCacheTtl = 1800;
      enableSshSupport = true;
      pinentryFlavor = "curses";
    };
  };
}
