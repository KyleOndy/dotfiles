{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.syncthing;
in
{
  options.systemFoundry.syncthing = {
    enable = mkEnableOption ''
      syncthing
    '';
  };

  config = mkIf cfg.enable {
    services.syncthing = {
      enable = true;
      user = "kyle";
      group = "users";
      configDir = "/home/kyle/.config/syncthing";
      openDefaultPorts = true;
      overrideDevices = true;
      overrideFolders = true;
      devices = {
        # to get syncthing key you need to install syncthing first.
        "alpha" = { id = "G5I3OAK-5O57DWJ-ZKPP6R3-J3KPCVB-EWMVN3L-UCV7ONL-TNOW2DO-3SJ3YAD"; };
        "omega" = { id = "CWYMQLD-JVLVARV-WFEWGR7-URPPQF2-3AAMP5E-IJASRHK-S2OTCEP-PCWNGAF"; };
        "tiger" = { id = "MWIARYQ-NO6ZDWT-4KINIBB-RFVW57A-6EAIHJF-KAOL4RH-QR7XSIV-SRFMXQ5"; };
        "sharptooth" = { id = "GAGCGYD-4YYIBIC-KPPDOYG-MAQS2FZ-OIWKTY3-IZTHVKN-NRNIL66-T7DATA2"; };
      };
      folders = {
        "testdir" = {
          path = "home/kyle/syncthing/test_sync_dir";
          devices = [ "alpha" "omega" ];
          #versioning = {
          #  type = "staggered";
          #  params = {
          #    cleanInterval = "3600"; # 1 hour
          #    maxAge = "15768000"; # 180 days
          #  };
          #};
        };
        "lightroom_catalog" = {
          path = "home/kyle/lightroom";
          devices = [ "alpha" "omega" ];
        };
        "synced_scratch" = {
          path = "home/kyle/synced_scratch";
          devices = [ "alpha" "omega" ];
        };
      };
    };
  };
}
