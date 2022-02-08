{ config, pkgs, ... }:
{
  imports =
    [
      ./hardware-configuration.nix
    ];
  # Use the GRUB 2 boot loader.
  boot = {
    loader.grub = {
      enable = true;
      version = 2;
      device = "/dev/sda";
    };
    binfmt.emulatedSystems = [ "aarch64-linux" ];
  };

  networking = {
    hostName = "util";
    defaultGateway = "10.25.89.1";
    nameservers = [ "10.25.89.1" ]; # todo: set to localhost?
    interfaces.eth0.ipv4.addresses = [{
      address = "10.25.89.53";
      prefixLength = 24;
    }];
  };


  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.11"; # Did you read the comment?

  networking.firewall = {
    allowedTCPPorts = [ 80 443 ];
  };
  users.users.nginx.extraGroups = [ "acme" ];
  sops.secrets = {
    namecheap = {
      owner = "acme";
      group = "acme";
    };
  };

  systemFoundry = {
    dnsServer = {
      enable = true;
      blacklist.enable = true;

      upstreamDnsServers = [ "10.25.89.1" ];
      # todo: why are the CNAMEs not working and I have to use A recorcs?
      aRecords = {
        "util.dmz.509ely.com" = "10.25.89.53";
        "grafana.apps.dmz.509ely.com" = "10.25.89.53";
        "jellyfin.apps.dmz.509ely.com" = "10.25.89.53";
        "nzbget.apps.dmz.509ely.com" = "10.25.89.53";
        "nzbhydra.apps.dmz.509ely.com" = "10.25.89.53";
        "radarr.apps.dmz.509ely.com" = "10.25.89.53";
        "sonarr.apps.dmz.509ely.com" = "10.25.89.53";
      };
      cnameRecords = {
        #"grafana.apps.dmz.509ely.com" = "util.dmz.509ely.com";
        #"jellyfin.apps.dmz.509ely.com" = "util.dmz.509ely.com";
        #"nzbget.apps.dmz.509ely.com" = "util.dmz.509ely.com";
        #"nzbhydra.apps.dmz.509ely.com" = "util.dmz.509ely.com";
        #"radarr.apps.dmz.509ely.com" = "util.dmz.509ely.com";
        #"sonarr.apps.dmz.509ely.com" = "util.dmz.509ely.com";
      };
      domainRecords = { };
    };
  };
}
