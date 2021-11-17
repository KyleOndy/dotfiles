{ config, pkgs, lib, ... }:

{
  boot = {
    kernelPackages = pkgs.linuxPackages_rpi4;
    tmpOnTmpfs = true;
    initrd.availableKernelModules = [ "usbhid" "usb_storage" ];
    # ttyAMA0 is the serial console broken out to the GPIO
    kernelParams = [
      "8250.nr_uarts=1"
      "console=ttyAMA0,115200"
      "console=tty1"
      # Some gui programs need this
      "cma=128M"
    ];
  };

  boot.loader.raspberryPi = {
    enable = true;
    version = 4;
  };
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # Required for the Wireless firmware
  hardware.enableRedistributableFirmware = true;

  networking = {
    hostName = "util";
    defaultGateway = "10.24.89.1";
    nameservers = [ "10.24.89.1" ]; # todo: set to localhost?
    interfaces.eth0.ipv4.addresses = [{
      address = "10.24.89.53";
      prefixLength = 24;
    }];
  };


  # Assuming this is installed on top of the disk image.
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" ];
    };
  };

  powerManagement.cpuFreqGovernor = "ondemand";
  system.stateVersion = "20.09";

  systemFoundry = {
    dnsServer = {
      enable = true;
      blacklist.enable = true;

      upstreamDnsServers = [ "10.24.89.1" ];
      aRecords = {
        # tood: these won't be needed if these hosts do dhcp
        "util.lan.509ely.com" = "10.24.89.53";

        # monitoring
        "prometheus.apps.lan.509ely.com" = "10.24.89.53";
        "grafana.apps.lan.509ely.com" = "10.24.89.53";

        # media server to deprecate
        "jellyfin.apps.lan.509ely.com" = "10.24.89.10";
        "nzbget.apps.lan.509ely.com" = "10.24.89.10";
        "nzbhydra.apps.lan.509ely.com" = "10.24.89.10";
        "radarr.apps.lan.509ely.com" = "10.24.89.10";
        "sonarr.apps.lan.509ely.com" = "10.24.89.10";
        "unifi.apps.lan.509ely.com" = "10.24.89.10";
      };
      cnameRecords = {
        #"unifi" = "unifi.apps.lan.509ely.com";
        #"nzbget.apps.lan.509ely.com" = "util.lan.509ely.com";
      };
      domainRecords = {
        "dmz.509ely.com" = "10.25.89.53";
      };
    };
    monitoring = {
      enable = true;
    };
  };
}

