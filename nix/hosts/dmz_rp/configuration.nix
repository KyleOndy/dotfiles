{ config, pkgs, ... }:

{
  imports =
    [ ./hardware-configuration.nix ];

  boot = {
    kernelPackages = pkgs.linuxPackages_rpi4;
    tmpOnTmpfs = true;
    loader = {
      grub.enable = false;
      raspberryPi = {
        enable = true;
        version = 4;
      };
    };
  };

  networking.hostName = "rp";

  networking.useDHCP = false;
  networking.interfaces.eth0.useDHCP = true;
  services.openssh.enable = true;

  system.stateVersion = "22.05"; # Did you read the comment?

  networking.firewall.allowedTCPPorts = [ 80 443 ];
  systemFoundry = {
    # TODO: lots of magic ports here, should clean this up.
    nginxReverseProxy = {
      "sonarr.apps.ondy.org" = {
        enable = true;
        provisionCert = true;
        proxyPass = "http://tiger.dmz.509ely.com:8989";
      };
      "radarr.apps.ondy.org" = {
        enable = true;
        provisionCert = true;
        proxyPass = "http://tiger.dmz.509ely.com:7878";
      };
      "jellyfin.apps.ondy.org" = {
        enable = true;
        provisionCert = true;
        proxyPass = "http://tiger.dmz.509ely.com:8096";
      };
      "nzbhydra.apps.ondy.org" = {
        enable = true;
        provisionCert = true;
        proxyPass = "http://tiger.dmz.509ely.com:5076";
      };
      "nzbget.apps.ondy.org" = {
        enable = true;
        provisionCert = true;
        proxyPass = "http://tiger.dmz.509ely.com:6789";
      };
      "gitea.apps.ondy.org" = {
        enable = true;
        provisionCert = true;
        proxyPass = "http://tiger.dmz.509ely.com:3000";
      };
    };
  };
}

