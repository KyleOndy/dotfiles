# Shared SSH host definitions
# This file contains all SSH hosts that can be used across different profiles

{ lib, ... }:
with lib;
{
  programs.ssh = {
    enable = true;
    extraConfig = ''
      IdentitiesOnly yes
      SendEnv LANG LC_*
    '';

    matchBlocks = {
      "*.compute-1.amazonaws.com" = {
        extraOptions = {
          UserKnownHostsFile = "/dev/null";
          StrictHostKeyChecking = "no";
        };
      };
      "tiger tiger.dmz.1ella.com" = {
        # 10.25.89.5
        hostname = "tiger.dmz.1ella.com";
        user = "kyle";
        port = 2332;
        identityFile = "~/.ssh/id_ed25519";
      };
      "dino" = {
        hostname = "dino.lan.1ella.com";
        user = "kyle";
        identityFile = "~/.ssh/id_ed25519";
      };
      "cheetah" = {
        hostname = "ns100099.ip-147-135-1.us";
        user = "kyle";
        identityFile = "~/.ssh/id_ed25519";
      };
    };
  };
}
