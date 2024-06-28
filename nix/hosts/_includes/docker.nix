{ config, pkgs, ... }:

{
  virtualisation.docker = {
    enable = true;
    extraOptions = "--registry-mirror=https://registry.apps.1ella.com";
  };

}
