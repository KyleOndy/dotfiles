{ config, pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };
  networking.hostName = "dmz-rp";
  system.stateVersion = "22.05"; # Did you read the comment?


  # =====================================================================
  # TODO: Refactor this out into moudles
  # =====================================================================
  networking.firewall.allowedTCPPorts = [ 80 443 ];
  services.nginx = {
    enable = true;

    # todo: make these options
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts = {
      "jellyfin.apps.ondy.org" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "https://jellyfin.apps.dmz.509ely.com";
        };
        extraConfig = ''
          access_log /var/log/nginx/jellyfin.access;
          error_log /var/log/nginx/jellyfin.error error;
        '';
      };
      "git.apps.ondy.org" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "https://gitea.apps.dmz.509ely.com";
        };
        extraConfig = ''
          access_log /var/log/nginx/git.access;
          error_log /var/log/nginx/git.error error;
        '';
      };
      "nix-cache.apps.ondy.org" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "https://nix-cache.apps.dmz.509ely.com";
        };
        extraConfig = ''
          access_log /var/log/nginx/nix-cache.access;
          error_log /var/log/nginx/nix-cache.error error;
        '';
      };
    };
  };
}

