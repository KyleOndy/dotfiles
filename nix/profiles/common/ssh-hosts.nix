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
      "*.amazonaws.com" = {
        extraOptions = {
          UserKnownHostsFile = "/dev/null";
          StrictHostKeyChecking = "no";
        };
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
      "elk" = {
        hostname = "37.27.70.102";
        user = "kyle";
        identityFile = "~/.ssh/id_ed25519";
      };
    };
  };
}
