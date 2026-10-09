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
    hash = "sha256-bIsACobQeWWlaJd//ityHiIQXs9tw2Lg2s2wi3VqLlc=";
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
  # alloy can ship these. Caddy's file writer defaults to 0600, which no
  # amount of group membership can get around.
  # Caddy redacts Cookie, Set-Cookie, Authorization and Proxy-Authorization
  # on its own, but nothing else. The *arr APIs authenticate with X-Api-Key
  # and an apikey query parameter, their SignalR sockets with access_token,
  # Jellyfin with ApiKey, api_key and X-Emby-Token or X-MediaBrowser-Token,
  # immich shared links with key, and Navidrome with a JWT in
  # X-Nd-Authorization (both ways) or jwt, plus the Subsonic API's t and s
  # (a salted password hash that replays until the password changes) or p
  # (the password itself). All of these would otherwise reach Loki in clear
  # text for the full 400 day retention. The `query` filter matches
  # parameter names case-sensitively, so a case-insensitive regexp covers
  # every spelling, in the Referer and Location URLs too. t, s and p go on
  # every site, which also blanks other apps' page and search parameters.
  # Header names arrive in Go's canonical form.
  secretParams = ''"(?i)([?&](?:api_?key|access_token|token|password|key|jwt|t|s|p)=)[^&#]*" "''${1}REDACTED"'';
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
        request>headers>X-Emby-Token delete
        request>headers>X-Mediabrowser-Token delete
        request>headers>X-Emby-Authorization delete
        request>headers>X-Nd-Authorization delete
        resp_headers>X-Nd-Authorization delete
        request>uri regexp ${secretParams}
        request>headers>Referer regexp ${secretParams}
        resp_headers>Location regexp ${secretParams}
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

  # The public wildcard DNS record and the router's 443 forward make every
  # infra name reachable from the internet. Caddy keeps same-directive
  # handle blocks with non-path matchers in source order, so @wan must come
  # first. remote_ip is the TCP peer, which a client cannot spoof with
  # headers the way it can client_ip.
  wildcardVhostBody = ''
    @wan not remote_ip private_ranges
    handle @wan {
      abort
    }

  ''
  + concatStringsSep "\n" (mapAttrsToList mkInfraSiteHandler infraSites)
  + ''

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

  # One entry per cert Caddy obtains, as "<label> <sni>". The wildcard is
  # reached through any one name it covers.
  certProbes =
    optional hasInfraSites "*.${cfg.infraDomain} ${head (attrNames infraSites)}"
    ++ map (n: "${n} ${n}") (
      attrNames externalSites
      ++ concatMap (s: s.extraDomainNames) (attrValues externalSites)
      ++ map (p: p.name) publicAliasSites
    );

  monitoringCfg = config.systemFoundry.monitoringStack;
  textfileEnabled = monitoringCfg.enable && monitoringCfg.nodeExporter.enable;
  certTextfile = "${monitoringCfg.nodeExporter.textfileDirectory}/caddy_certs.prom";

  # Probes 127.0.0.1 with each name as SNI rather than the public address:
  # tiger cannot reach its own WAN IP, and this is the cert Caddy serves
  # whatever DNS says.
  certProbeScript = pkgs.writeShellApplication {
    name = "caddy-cert-probe";
    runtimeInputs = [
      pkgs.openssl
      pkgs.coreutils
    ];
    text = ''
      readonly OUTFILE=${escapeShellArg certTextfile}
      tmp=$(mktemp "$OUTFILE.XXXXXX")
      {
        printf '# HELP tls_cert_not_before_timestamp_seconds Unix time the served cert became valid\n'
        printf '# TYPE tls_cert_not_before_timestamp_seconds gauge\n'
        printf '# HELP tls_cert_not_after_timestamp_seconds Unix time the served cert expires\n'
        printf '# TYPE tls_cert_not_after_timestamp_seconds gauge\n'
        printf '# HELP tls_cert_probe_success 1 if a TLS handshake for this name returned a cert\n'
        printf '# TYPE tls_cert_probe_success gauge\n'
        while read -r label sni; do
          dates=$(timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$sni" </dev/null 2>/dev/null \
            | openssl x509 -noout -startdate -enddate 2>/dev/null || true)
          if [[ -z "$dates" ]]; then
            printf 'tls_cert_probe_success{name="%s"} 0\n' "$label"
            continue
          fi
          before=$(date -d "$(sed -n 's/^notBefore=//p' <<<"$dates")" +%s)
          after=$(date -d "$(sed -n 's/^notAfter=//p' <<<"$dates")" +%s)
          printf 'tls_cert_probe_success{name="%s"} 1\n' "$label"
          printf 'tls_cert_not_before_timestamp_seconds{name="%s"} %s\n' "$label" "$before"
          printf 'tls_cert_not_after_timestamp_seconds{name="%s"} %s\n' "$label" "$after"
        done <<'EOF'
      ${concatStringsSep "\n" certProbes}
      EOF
        printf '# HELP tls_cert_probe_timestamp_seconds Unix time of the last probe run\n'
        printf '# TYPE tls_cert_probe_timestamp_seconds gauge\n'
        printf 'tls_cert_probe_timestamp_seconds %s\n' "$(date +%s)"
      } >"$tmp"
      chmod 0644 "$tmp"
      mv -fT "$tmp" "$OUTFILE"
    '';
  };
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

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open 80 and 443 on every interface. Disable to open them per interface instead.";
    };

    metricsPort = mkOption {
      type = types.port;
      default = 2020;
      description = "Port on 127.0.0.1 where Caddy serves its Prometheus metrics.";
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
      #
      # The admin API replaces Caddy's whole config on request, with no auth,
      # so it listens where only caddy can reach it; `caddy reload` reads the
      # address from the config it loads. Metrics get a loopback site with no
      # log block, which keeps scrapes out of the access logs Alloy ships.
      globalConfig = ''
        email ${cfg.acme.email}
        acme_dns route53
        metrics
        admin unix//run/caddy/admin.sock
      '';
      extraConfig = ''
        http://127.0.0.1:${toString cfg.metricsPort} {
          bind 127.0.0.1
          metrics
        }
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
    systemd.services.caddy.serviceConfig = {
      EnvironmentFile = config.sops.secrets.${cfg.acme.credentialsSecret}.path;
      RuntimeDirectory = "caddy";
      RuntimeDirectoryMode = "0700";
    };

    # `mode 640` only governs files Caddy creates from here on. Logs already on
    # disk keep the 0600 they were opened with until they roll.
    systemd.tmpfiles.rules = [
      "z ${config.services.caddy.logDir}/access-*.log 0640 caddy caddy -"
    ]
    # The textfile directory is sticky, so a file any other user owns blocks
    # the rename that replaces it.
    ++ optional textfileEnabled "z ${certTextfile} 0644 caddy textfile -";

    systemd.services.caddy-cert-probe = mkIf textfileEnabled {
      description = "Export expiry of the certs Caddy serves to node_exporter textfile";
      after = [ "caddy.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "caddy";
        Group = "caddy";
        SupplementaryGroups = [ "textfile" ];
        ExecStart = getExe certProbeScript;
        ReadWritePaths = [ monitoringCfg.nodeExporter.textfileDirectory ];
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };
    };

    systemd.timers.caddy-cert-probe = mkIf textfileEnabled {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "15min";
      };
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [
      80
      443
    ];
  };
}
