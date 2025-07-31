{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.pxe-api;
in
{
  options.systemFoundry.pxe-api = {
    enable = mkEnableOption ''
      Hand rolled pxe api to manage my homelab
    '';
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open firewall ports";
    };
    # todo: make these configurable
    #listenHost = mkOption { type = types.str; };
    #listenPort = mkOption { type = types.int; };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = mfIf cfg.openFirewall [ cfg.listenPort ];

    systemd.services.pxe-api = {
      enable = true;
      description = "run pxe-api";
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.nix ];
      serviceConfig = {
        ExecStart = "${pkgs.pxe-api}/bin/pxe-api";
      };
    };
  };
}
