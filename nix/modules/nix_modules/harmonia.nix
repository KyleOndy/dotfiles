# https://github.com/nix-community/harmonia
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.harmonia;
in
{
  options.systemFoundry.harmonia = {
    enable = mkEnableOption ''
      Nix binary cache implemented in rust
    '';

    domainName = mkOption {
      type = types.str;
      description = "Domain name to serve harmonia under";
      example = "cache.apps.ondy.org";
    };

    provisionCert = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Provision a Let's Encrypt certificate for this service via nginxReverseProxy.
        Requires nginxReverseProxy.acme to be configured.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.harmonia = {
      enable = true;
      # generate this key in situ with the following command:
      # $ nix-store --generate-binary-cache-key cache.yourdomain.tld-1 /var/lib/secrets/harmonia.secret /var/lib/secrets/harmonia.pub
      signKeyPaths = [ "/var/lib/secrets/harmonia.secret" ];
    };

    # harmonia runs on :5000, proxy it via nginx with TLS
    systemFoundry.nginxReverseProxy.sites."${cfg.domainName}" = {
      enable = true;
      provisionCert = cfg.provisionCert;
      proxyPass = "http://127.0.0.1:5000";
      route53HostedZoneId = "Z0365859SHHFAPNR0QXN";
    };
  };
}
