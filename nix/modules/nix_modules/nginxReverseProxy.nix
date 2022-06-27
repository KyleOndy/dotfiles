{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.nginxReverseProxy;
in
{
  options.systemFoundry.nginxReverseProxy = mkOption {
    default = { };
    description = "nginx reverse proxy instance";
    type = types.attrsOf (types.submodule {
      options = {

        enable = mkEnableOption ''
          Create an nginx reverse proxy with optional cers
        '';
        location = mkOption {
          type = types.str;
          default = "/";
          description = ''
            loction under domain
          '';
        };
        extraDomainNames = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "additional cnames to add to cert";
        };
        provisionCert = mkOption {
          type = types.bool;
          default = true;
          description = ''
            provision a cert for this reverse proxy
          '';
        };
        proxyPass = mkOption {
          type = types.str;
          description = "path to proxy this domainnam to";
          example = ''
            http://127.0.0.1:8989
          '';
        };
      };
    });
  };

  config =
    let
      sites = lib.filterAttrs (_: cfg: cfg.enable) config.systemFoundry.nginxReverseProxy;
    in
    {
      services.nginx = {
        enable = true;

        # todo: make these options
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;

        virtualHosts = lib.attrsets.mapAttrs
          (name: cfg: {
            enableACME = false;
            forceSSL = true;

            # todo: should I make the path configurable?
            sslCertificate = "/var/lib/acme/${name}/cert.pem";
            sslCertificateKey = "/var/lib/acme/${name}/key.pem";
            locations."/" = {
              proxyPass = cfg.proxyPass;
              # todo: these may need to be configurable
              extraConfig =
                # required when the target is also TLS server with multiple hosts
                #"proxy_ssl_server_name on;" +
                # required when the server wants to use HTTP Authentication
                "proxy_pass_header Authorization;"
              ;
            };
            extraConfig = ''
              access_log /var/log/nginx/${name}.access;
              error_log /var/log/nginx/${name}.error error;
            '';
          })
          sites;
      };
      security.acme = {
        certs = mapAttrs
          (name: cfg: { extraDomainNames = cfg.extraDomainNames; })
          sites;
      };
      users.users.nginx.extraGroups = [ "acme" ];
      sops.secrets.namecheap = {
        owner = "acme";
        group = "acme";
      };
      networking.firewall.allowedTCPPorts = [ 80 443 ];
    };
}
