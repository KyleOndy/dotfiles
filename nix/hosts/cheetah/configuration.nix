{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [ ./hardware-configuration.nix ];

  networking = {
    hostName = "cheetah";
  };

  time.timeZone = "America/New_York";
  i18n = {
    defaultLocale = "en_US.UTF-8";
    extraLocaleSettings = {
      LC_ALL = "en_US.UTF-8";
    };
  };

  boot.binfmt.emulatedSystems = [
    "aarch64-linux"
    "armv7l-linux"
  ];

  # Configure mdadm to send notifications to root for RAID events
  boot.swraid.mdadmConf = "MAILADDR root@localhost";

  systemFoundry = {
    nginxReverseProxy.acme = {
      email = "kyle@ondy.org";
      dnsProvider = "route53";
      credentialsSecret = "apps_ondy_org_route53";
    };

    harmonia = {
      enable = true;
      domainName = "nix-cache.apps.ondy.org";
      provisionCert = true;
    };
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05";
}
