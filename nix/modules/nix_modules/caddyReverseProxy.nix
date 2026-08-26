{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.caddyReverseProxy;

  # Custom Caddy build with Route53 DNS plugin for ACME DNS-01 challenge.
  # To get the correct hash: build once with lib.fakeHash, read the hash from the error, update here.
  caddyWithPlugins = pkgs.caddy.withPlugins {
    plugins = [ "github.com/caddy-dns/route53@v1.6.0" ];
    hash = "sha256-CbbS8vxaBotf2iyiqrmJHSlTXgWFLM7c2IMusFJWdXw=";
  };

  enabledSites = filterAttrs (_: s: s.enable) cfg.sites;
  anySiteEnabled = enabledSites != { };

  # Sites under infraDomain share a wildcard cert in one vhost block
  infraSites = optionalAttrs (cfg.infraDomain != null) (
    filterAttrs (name: _: hasSuffix ".${cfg.infraDomain}" name) enabledSites
  );
  hasInfraSites = infraSites != { };

  # Sites outside infraDomain each get their own vhost with individual cert
  externalSites = filterAttrs (
    name: site:
    site.enable && !site.isDefault && !(cfg.infraDomain != null && hasSuffix ".${cfg.infraDomain}" name)
  ) cfg.sites;

  # The catch-all isDefault site (maps to http:// catch-all in Caddy)
  defaultSiteEntry =
    let
      entries = filter (x: x.value.isDefault) (mapAttrsToList nameValuePair enabledSites);
    in
    if entries != [ ] then head entries else null;

  # Make a safe Caddyfile identifier from any string
  safeName = s: replaceStrings [ "-" "." "*" "/" ":" ] [ "_" "_" "star" "_" "_" ] s;

  # Same path the NixOS caddy module derives, with a group-readable mode so
  # promtail can ship these. Caddy's file writer defaults to 0600, which no
  # amount of group membership can get around.
  # Caddy redacts Cookie and Authorization on its own, but nothing else. The
  # *arr APIs and immich authenticate with X-Api-Key and with an apikey query
  # parameter, both of which would otherwise reach Loki in clear text and sit
  # there for the full 400 day retention.
  accessLogFormat = hostName: ''
    output file ${config.services.caddy.logDir}/access-${
      replaceStrings [ "/" " " ] [ "_" "_" ] hostName
    }.log {
      mode 640
    }
    format filter {
      wrap json
      fields {
        request>headers>X-Api-Key delete
        request>uri query {
          replace apikey REDACTED
          replace api_key REDACTED
          replace token REDACTED
          replace password REDACTED
        }
      }
    }
  '';

  # Generate basicauth directives for a site
  mkBasicAuth =
    site:
    optionalString (site.basicAuth != null) (
      if site.basicAuthPaths == [ ] then
        ''
          basic_auth {
            import ${toString site.basicAuth}
          }
        ''
      else
        ''
          @auth_paths path ${concatStringsSep " " site.basicAuthPaths}
          basic_auth @auth_paths {
            import ${toString site.basicAuth}
          }
        ''
    );

  # Generate the body of a site block (auth + content directive + extra config)
  mkSiteBody =
    name: site:
    let
      redirectTarget = if site.extraDomainNames != [ ] then head site.extraDomainNames else name;
      contentDirective =
        if site.proxyPass != null then
          let
            proxyBlockBody =
              optionalString (site.flushInterval != null) "  flush_interval ${site.flushInterval}\n"
              + optionalString (site.proxyTimeout != null) (
                "  transport http {\n"
                + "    dial_timeout ${site.proxyTimeout}\n"
                + "    response_header_timeout ${site.proxyTimeout}\n"
                + "  }\n"
              );
          in
          "reverse_proxy ${site.proxyPass}" + optionalString (proxyBlockBody != "") " {\n${proxyBlockBody}}"
        else if site.staticRoot != null then
          ''
            root * ${toString site.staticRoot}
            file_server
          ''
        else if site.redirectTo != null then
          "redir https://${site.redirectTo}{uri} permanent"
        else if site.isDefault then
          "redir https://${redirectTarget}{uri}"
        else
          "";
    in
    (mkBasicAuth site) + contentDirective + "\n" + site.extraCaddyConfig;

  # Generate a host-matcher routing block for use inside the wildcard vhost
  mkInfraSiteHandler = name: site: ''
    @${safeName name} host ${name}
    handle @${safeName name} {
      ${mkSiteBody name site}
    }
  '';

  wildcardVhostBody = concatStringsSep "\n" (mapAttrsToList mkInfraSiteHandler infraSites) + ''

    handle {
      abort
    }
  '';

  # Public alias vhosts from infra sites (e.g. jellyfin.apps.ondy.org alongside infra domain)
  publicAliasSites = flatten (
    mapAttrsToList (
      name: site: map (alias: nameValuePair alias { inherit name site; }) site.publicAliases
    ) infraSites
  );
in
{
  options.systemFoundry.caddyReverseProxy = {
    enable = mkEnableOption "Caddy-based reverse proxy with automatic HTTPS via Route53 DNS-01";

    acme = {
      email = mkOption {
        type = types.str;
        description = "ACME account email for Let's Encrypt";
        example = "kyle@ondy.org";
      };
      credentialsSecret = mkOption {
        type = types.str;
        description = "Sops secret name with AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY for Route53 DNS-01 challenge";
        example = "apps_ondy_org_route53";
      };
    };

    infraDomain = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Infra base domain. Sites matching *.<infraDomain> share a single wildcard cert.";
      example = "tiger.infra.ondy.org";
    };

    sites = mkOption {
      default = { };
      description = "Caddy reverse proxy sites";
      type = types.attrsOf (
        types.submodule {
          options = {
            enable = mkEnableOption "Create a Caddy reverse proxy site";

            extraDomainNames = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "For isDefault: the redirect target. For external sites: additional SAN names.";
            };

            proxyPass = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Upstream URL to reverse proxy";
              example = "http://127.0.0.1:8080";
            };

            staticRoot = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Serve static files from this directory";
            };

            isDefault = mkOption {
              type = types.bool;
              default = false;
              description = "Catch-all HTTP handler that redirects to first extraDomainName or site name";
            };

            redirectTo = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "301 redirect all requests to this domain";
            };

            publicAliases = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Public domain aliases that get individual vhosts with their own certs";
            };

            proxyTimeout = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Dial and response timeout for the upstream connection (e.g. '300s')";
            };

            flushInterval = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "flush_interval for reverse_proxy. Use '-1' to disable buffering (recommended for streaming).";
            };

            extraCaddyConfig = mkOption {
              type = types.lines;
              default = "";
              description = "Additional Caddy directives appended to this site block";
            };

            basicAuth = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Path to credentials file with 'username bcrypt-hash' lines (one per line)";
            };

            basicAuthPaths = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "URL paths to protect with basicAuth. Empty list = protect all paths.";
            };
          };
        }
      );
    };
  };

  config = mkIf (cfg.enable && anySiteEnabled) {
    assertions = [
      {
        assertion = !config.services.nginx.enable;
        message = "caddyReverseProxy: services.nginx.enable is true. Disable nginx before enabling Caddy (both cannot bind to ports 80/443)";
      }
    ];

    services.caddy = {
      enable = true;
      package = caddyWithPlugins;

      # Global block: ACME email, Route53 DNS-01 challenge, Prometheus metrics
      # endpoint. `per_host` is deliberately absent: it labels series with the
      # raw request Host, which on a public :443 grows a permanent series for
      # every header a scanner sends. Per-site traffic comes from the access
      # logs in Loki instead.
      globalConfig = ''
        email ${cfg.acme.email}
        acme_dns route53
        metrics
      '';

      virtualHosts = mkMerge [
        # One wildcard vhost for all infra-domain sites (*.<infraDomain>)
        (optionalAttrs hasInfraSites {
          "*.${cfg.infraDomain}" = {
            logFormat = accessLogFormat "*.${cfg.infraDomain}";
            extraConfig = wildcardVhostBody;
          };
        })

        # Individual vhosts for non-infra external sites (e.g. www.kyleondy.com)
        (mapAttrs (_name: site: {
          serverAliases = site.extraDomainNames;
          logFormat = accessLogFormat _name;
          extraConfig = mkSiteBody _name site;
        }) externalSites)

        # Public alias vhosts from infra sites (e.g. jellyfin.apps.ondy.org)
        (listToAttrs (
          map (pair: {
            name = pair.name;
            value = {
              logFormat = accessLogFormat pair.name;
              extraConfig = mkSiteBody pair.name pair.value.site;
            };
          }) publicAliasSites
        ))

        # HTTP catch-all for isDefault redirect sites
        (optionalAttrs (defaultSiteEntry != null) {
          "http://" = {
            logFormat = accessLogFormat "http://";
            extraConfig =
              let
                site = defaultSiteEntry.value;
                siteName = defaultSiteEntry.name;
                target = if site.extraDomainNames != [ ] then head site.extraDomainNames else siteName;
              in
              "redir https://${target}{uri}";
          };
        })
      ];
    };

    # Route53 credentials for ACME DNS-01 (read by systemd as root before privilege drop)
    systemd.services.caddy.serviceConfig.EnvironmentFile =
      config.sops.secrets.${cfg.acme.credentialsSecret}.path;

    # `mode 640` only governs files Caddy creates from here on. Logs already on
    # disk keep the 0600 they were opened with until they roll.
    systemd.tmpfiles.rules = [
      "z ${config.services.caddy.logDir}/access-*.log 0640 caddy caddy -"
    ];

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
