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

  ## todo: refactor into moudles


  services = {
    nzbget = {
      enable = true;
      settings = {
        MainDir = "/srv/media/nzbget";
        #ControlUsername = "kyle";
        #ControlPassword = "hunter2";
      };
    };
    nzbhydra2 = {
      enable = true;
    };
    radarr = {
      enable = true;
    };
    sonarr = {
      enable = true;
    };
    transmission = {
      enable = true;
    };
    jellyfin = {
      enable = true;
      openFirewall = true;
    };
    unifi = {
      enable = true;
      unifiPackage = pkgs.unifiStable;
    };
    nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      # other Nginx options

      # todo: clean this up with a iteration over a map
      virtualHosts."nzbget.apps.dmz.509ely.com" = {
        enableACME = false;
        forceSSL = true;
        sslCertificate = "/var/lib/acme/star.apps.dmz.509ely.com/cert.pem";
        sslCertificateKey = "/var/lib/acme/star.apps.dmz.509ely.com/key.pem";
        locations."/" = {
          proxyPass = "http://127.0.0.1:6789";
          extraConfig =
            # required when the target is also TLS server with multiple hosts
            #"proxy_ssl_server_name on;" +
            # required when the server wants to use HTTP Authentication
            "proxy_pass_header Authorization;"
          ;
        };
      };
      virtualHosts."nzbhydra.apps.dmz.509ely.com" = {
        enableACME = false;
        forceSSL = true;
        sslCertificate = "/var/lib/acme/star.apps.dmz.509ely.com/cert.pem";
        sslCertificateKey = "/var/lib/acme/star.apps.dmz.509ely.com/key.pem";
        locations."/" = {
          proxyPass = "http://127.0.0.1:5076";
          extraConfig =
            # required when the target is also TLS server with multiple hosts
            #"proxy_ssl_server_name on;" +
            # required when the server wants to use HTTP Authentication
            "proxy_pass_header Authorization;"
          ;
        };
      };
      virtualHosts."sonarr.apps.dmz.509ely.com" = {
        enableACME = false;
        forceSSL = true;
        sslCertificate = "/var/lib/acme/star.apps.dmz.509ely.com/cert.pem";
        sslCertificateKey = "/var/lib/acme/star.apps.dmz.509ely.com/key.pem";
        locations."/" = {
          proxyPass = "http://127.0.0.1:8989";
          extraConfig =
            # required when the target is also TLS server with multiple hosts
            #"proxy_ssl_server_name on;" +
            # required when the server wants to use HTTP Authentication
            "proxy_pass_header Authorization;"
          ;
        };
      };
      virtualHosts."radarr.apps.dmz.509ely.com" = {
        enableACME = false;
        forceSSL = true;
        sslCertificate = "/var/lib/acme/star.apps.dmz.509ely.com/cert.pem";
        sslCertificateKey = "/var/lib/acme/star.apps.dmz.509ely.com/key.pem";
        locations."/" = {
          proxyPass = "http://127.0.0.1:7878";
          extraConfig =
            # required when the target is also TLS server with multiple hosts
            #"proxy_ssl_server_name on;" +
            # required when the server wants to use HTTP Authentication
            "proxy_pass_header Authorization;"
          ;
        };
      };
      virtualHosts."jellyfin.apps.dmz.509ely.com" = {
        enableACME = false;
        forceSSL = true;
        sslCertificate = "/var/lib/acme/star.apps.dmz.509ely.com/cert.pem";
        sslCertificateKey = "/var/lib/acme/star.apps.dmz.509ely.com/key.pem";
        locations."/" = {
          proxyPass = "http://127.0.0.1:8096";
          proxyWebsockets = true;
          extraConfig =
            # required when the target is also TLS server with multiple hosts
            #"proxy_ssl_server_name on;" +
            # required when the server wants to use HTTP Authentication
            "proxy_pass_header Authorization;" +
            "proxy_buffering off;"
          ;
        };
      };
      virtualHosts."unifi.apps.dmz.509ely.com" = {
        enableACME = false;
        forceSSL = true;
        sslCertificate = "/var/lib/acme/star.apps.dmz.509ely.com/cert.pem";
        sslCertificateKey = "/var/lib/acme/star.apps.dmz.509ely.com/key.pem";
        locations."/" = {
          proxyPass = "https://127.0.0.1:8443";
          extraConfig =
            "proxy_ssl_verify off;" +

            # for uploading and restoring backups
            "client_max_body_size 100M;" +
            # required when the target is also TLS server with multiple hosts
            #
            #"proxy_ssl_server_name on;" +
            # required when the server wants to use HTTP Authentication
            "proxy_pass_header Authorization;"
          ;
        };
      };
    };
  };
  security.acme = {
    certs = {
      "star.apps.dmz.509ely.com" = {
        # todo: make *
        dnsProvider = "namecheap";
        credentialsFile = config.sops.secrets.namecheap.path;
        extraDomainNames = [
          "nzbget.apps.dmz.509ely.com"
          "nzbhydra.apps.dmz.509ely.com"
          "sonarr.apps.dmz.509ely.com"
          "radarr.apps.dmz.509ely.com"
          "transmission.apps.dmz.509ely.com"
          "jellyfin.apps.dmz.509ely.com"
          "unifi.apps.dmz.509ely.com"
        ];
      };
    };
  };
  networking.firewall = {
    allowedTCPPorts = [ 80 443 ];
  };
  users.groups.media.members = [
    "nzbget"
    "sonarr"
    "radarr"
    "jellyfin"
  ];
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
