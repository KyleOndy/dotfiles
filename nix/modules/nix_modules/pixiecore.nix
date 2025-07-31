{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.pixiecore;
in
{
  options.systemFoundry.pixiecore = {
    enable = mkEnableOption ''
      Pixiecore is an tool to manage network booting of machines. It can be used
      for simple single shot network boots, or as a building block of machine
      management infrastructure.

      NOTE: this is hardcoded to work in API mode.
    '';
    listenPort = mkOption {
      type = types.int;
      description = "Port that pixiecore listens on";
    };
    apiAddress = mkOption {
      type = types.str;
      description = "Address of requisete API server";
      example = "http://localhost:3031";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open firewall ports";
      example = "3032";
    };
  };

  config = mkIf cfg.enable {

    #environment.systemPackages = with pkgs; [ pixiecore ];
    networking.firewall.allowedUDPPorts = mfIf cfg.openFirewall [ cfg.listenPort ];

    systemd.services.pixiecore = {
      enable = true;
      description = "run pixiecore API";
      unitConfig = {
        Type = "simple";
      };
      serviceConfig = {
        ExecStart = "${pkgs.pixiecore}/bin/pixiecore api ${cfg.apiAddress} -p ${toString cfg.listenPort}";
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}
