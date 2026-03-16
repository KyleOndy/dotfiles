# Shared SSH host definitions
# This file contains all SSH hosts that can be used across different profiles

{ lib, ... }:
with lib;
{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    matchBlocks = {
      "*" = {
        extraOptions = {
          IdentitiesOnly = "yes";
          SendEnv = "LANG LC_*";
        };
      };
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
      "wolf" = {
        hostname = "ns568215.ip-51-79-99.net";
        user = "kyle";
        identityFile = "~/.ssh/id_ed25519";
      };
      "bear" = {
        hostname = "ns102788.ip-147-135-8.us";
        user = "kyle";
        identityFile = "~/.ssh/id_ed25519";
      };
      "elk" = {
        hostname = "37.27.70.102";
        user = "kyle";
        identityFile = "~/.ssh/id_ed25519";
      };
    };
  };
}
