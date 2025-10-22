{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.nginxReverseProxy;
in
{
  options.systemFoundry.nginxReverseProxy = {
    acme = {
      email = mkOption {
        type = types.str;
        description = "ACME account email for Let's Encrypt";
        example = "admin@example.com";
      };
      dnsProvider = mkOption {
        type = types.str;
        description = "DNS provider for DNS-01 ACME challenge";
        example = "namecheap";
      };
      credentialsSecret = mkOption {
        type = types.str;
        description = "Name of the sops secret containing DNS provider credentials";
        example = "namecheap";
      };
    };

    appendHttpConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Additional configuration to append to the http block (e.g., map directives)";
    };

    sites = mkOption {
      default = { };
      description = "Nginx reverse proxy sites";
      type = types.attrsOf (
        types.submodule {
          options = {

            enable = mkEnableOption ''
              Create an nginx reverse proxy with optional certs
            '';
            location = mkOption {
              type = types.str;
              default = "/";
              description = ''
                Location path under domain
              '';
            };
            extraDomainNames = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Additional CNAMEs to add to certificate";
            };
            provisionCert = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Provision a Let's Encrypt certificate for this reverse proxy
              '';
            };
            proxyPass = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "URL to proxy this domain to";
              example = ''
                http://127.0.0.1:8989
              '';
            };
            staticRoot = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = ''
                Path to serve static files from.
                Mutually exclusive with proxyPass.
              '';
              example = "/var/www/example.com";
            };
            isDefault = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Make this the default server block that catches all requests
                not matched by other server blocks. When enabled, this will
                redirect all traffic to the first domain in extraDomainNames
                or the site name if no extraDomainNames are specified.
              '';
            };
            enableSSLVerify = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Enable SSL certificate verification for upstream HTTPS connections.
                Only relevant when proxyPass uses https://.
              '';
            };
            route53HostedZoneId = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Route53 hosted zone ID for DNS-01 ACME challenge.
                Only relevant when using route53 as dnsProvider.
                If not specified, lego will attempt to auto-detect the zone.
              '';
              example = "Z0855021CRZ8TKMBC7EC";
            };
            extraConfig = mkOption {
              type = types.lines;
              default = "";
              description = ''
                Additional nginx configuration for this location block.
                Useful for authentication checks, rate limiting, etc.
              '';
            };
          };
        }
      );
    };
  };

  config =
    let
      enabledSites = lib.filterAttrs (_: siteCfg: siteCfg.enable) cfg.sites;
      anySiteEnabled = enabledSites != { };
      sitesWithCerts = lib.filterAttrs (_: siteCfg: siteCfg.provisionCert) enabledSites;
      anyNeedsCerts = sitesWithCerts != { };
    in
    mkIf anySiteEnabled {
      assertions = [
        {
          assertion = !anyNeedsCerts || (cfg.acme ? email && cfg.acme.email != "");
          message = "nginxReverseProxy: acme.email is required when provisionCert is enabled on any site";
        }
        {
          assertion = !anyNeedsCerts || (cfg.acme ? dnsProvider && cfg.acme.dnsProvider != "");
          message = "nginxReverseProxy: acme.dnsProvider is required when provisionCert is enabled on any site";
        }
        {
          assertion = !anyNeedsCerts || (cfg.acme ? credentialsSecret && cfg.acme.credentialsSecret != "");
          message = "nginxReverseProxy: acme.credentialsSecret is required when provisionCert is enabled on any site";
        }
      ]
      ++ lib.flatten (
        lib.mapAttrsToList (name: siteCfg: [
          {
            assertion = siteCfg.proxyPass != null || siteCfg.staticRoot != null || siteCfg.isDefault;
            message = "nginxReverseProxy.${name}: must specify either proxyPass, staticRoot, or isDefault";
          }
          {
            assertion = !(siteCfg.proxyPass != null && siteCfg.staticRoot != null);
            message = "nginxReverseProxy.${name}: proxyPass and staticRoot are mutually exclusive";
          }
        ]) enabledSites
      );
      services.nginx = {
        enable = true;

        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;

        clientMaxBodySize = "512m";

        # Increase map hash bucket size to accommodate SHA-256 hash keys (64 bytes)
        mapHashBucketSize = 128;

        commonHttpConfig = ''
          log_format upstreamlog '[$time_local] $remote_addr - $remote_user - $server_name to: $upstream_addr: $request upstream_response_time $upstream_response_time msec $msec request_time $request_time';

          log_format verbose  "[$time_local] $status \"$request\"\n"
                      " -> args=\"$args\" \n"
                      " -> binary_remote_addr=\"$binary_remote_addr\" \n"
                      " -> body_bytes_sent=\"$body_bytes_sent\" \n"
                      " -> bytes_sent=\"$bytes_sent\" \n"
                      " -> connection=\"$connection\" \n"
                      " -> connection_requests=\"$connection_requests\" \n"
                      " -> connections_active=\"$connections_active\" \n"
                      " -> connections_reading=\"$connections_reading\" \n"
                      " -> connections_waiting=\"$connections_waiting\" \n"
                      " -> connections_writing=\"$connections_writing\" \n"
                      " -> content_length=\"$content_length\" \n"
                      " -> content_type=\"$content_type\" \n"
                      " -> document_root=\"$document_root\" \n"
                      " -> document_uri=\"$document_uri\" \n"
                      " -> gzip_ratio=\"$gzip_ratio\" \n"
                      " -> host=\"$host\" \n"
                      " -> hostname=\"$hostname\" \n"
                      " -> http2=\"$http2\" \n"
                      " -> http_cookie=\"$http_cookie\" \n"
                      " -> http_referer=\"$http_referer\" \n"
                      " -> http_user_agent=\"$http_user_agent\" \n"
                      " -> http_x_forwarded_for=\"$http_x_forwarded_for\" \n"
                      " -> http_x_header=\"$http_x_header\" \n"
                      " -> is_args=\"$is_args\" \n"
                      " -> limit_conn_status=\"$limit_conn_status\" \n"
                      " -> limit_rate=\"$limit_rate\" \n"
                      " -> limit_req_status=\"$limit_req_status\" \n"
                      " -> modern_browser=\"$modern_browser\" \n"
                      " -> msec=\"$msec\" \n"
                      " -> msie=\"$msie\" \n"
                      " -> nginx_version=\"$nginx_version\" \n"
                      " -> pid=\"$pid\" \n"
                      " -> pipe=\"$pipe\" \n"
                      " -> proxy_host=\"$proxy_host\" \n"
                      " -> proxy_port=\"$proxy_port\" \n"
                      " -> proxy_protocol_addr=\"$proxy_protocol_addr\" \n"
                      " -> proxy_protocol_port=\"$proxy_protocol_port\" \n"
                      " -> proxy_protocol_server_addr=\"$proxy_protocol_server_addr\" \n"
                      " -> proxy_protocol_server_port=\"$proxy_protocol_server_port\" \n"
                      " -> query_string=\"$query_string\" \n"
                      " -> realip_remote_addr=\"$realip_remote_addr\" \n"
                      " -> realip_remote_port=\"$realip_remote_port\" \n"
                      " -> realpath_root=\"$realpath_root\" \n"
                      " -> remote_addr=\"$remote_addr\" \n"
                      " -> remote_port=\"$remote_port\" \n"
                      " -> remote_user=\"$remote_user\" \n"
                      " -> request=\"$request\" \n"
                      " -> request_body=\"$request_body\" \n"
                      " -> request_body_file=\"$request_body_file\" \n"
                      " -> request_completion=\"$request_completion\" \n"
                      " -> request_filename=\"$request_filename\" \n"
                      " -> request_id=\"$request_id\" \n"
                      " -> request_length=\"$request_length\" \n"
                      " -> request_method=\"$request_method\" \n"
                      " -> request_time=\"$request_time\" \n"
                      " -> request_uri=\"$request_uri\" \n"
                      " -> scheme=\"$scheme\" \n"
                      " -> server_addr=\"$server_addr\" \n"
                      " -> server_name=\"$server_name\" \n"
                      " -> server_port=\"$server_port\" \n"
                      " -> server_protocol=\"$server_protocol\" \n"
                      " -> status=\"$status\" \n"
                      " -> tcpinfo_rcv_space=\"$tcpinfo_rcv_space\" \n"
                      " -> tcpinfo_rtt=\"$tcpinfo_rtt\" \n"
                      " -> tcpinfo_rttvar=\"$tcpinfo_rttvar\" \n"
                      " -> tcpinfo_snd_cwnd=\"$tcpinfo_snd_cwnd\" \n"
                      " -> time_iso8601=\"$time_iso8601\" \n"
                      " -> upstream_addr=\"$upstream_addr\" \n"
                      " -> upstream_bytes_received=\"$upstream_bytes_received\" \n"
                      " -> upstream_bytes_sent=\"$upstream_bytes_sent\" \n"
                      " -> upstream_cache_status=\"$upstream_cache_status\" \n"
                      " -> upstream_connect_time=\"$upstream_connect_time\" \n"
                      " -> upstream_header_time=\"$upstream_header_time\" \n"
                      " -> upstream_response_length=\"$upstream_response_length\" \n"
                      " -> upstream_response_time=\"$upstream_response_time\" \n"
                      " -> upstream_status=\"$upstream_status\" \n"
                      " -> uri=\"$uri\" \n"
                      "\n";

          ${cfg.appendHttpConfig}
        '';
        virtualHosts = lib.attrsets.mapAttrs (
          name: siteCfg:
          let
            # Determine redirect target for default server
            redirectTarget =
              if siteCfg.isDefault then
                if (builtins.length siteCfg.extraDomainNames) > 0 then
                  builtins.head siteCfg.extraDomainNames
                else
                  name
              else
                null;
          in
          {
            enableACME = siteCfg.provisionCert && !siteCfg.isDefault;
            forceSSL = siteCfg.provisionCert && !siteCfg.isDefault;
            default = siteCfg.isDefault;

            # Configure root for static sites
            root = if siteCfg.staticRoot != null then siteCfg.staticRoot else null;

            # Configure locations
            locations =
              if siteCfg.isDefault then
                # Default server: redirect everything
                {
                  "/" = {
                    return = "301 https://${redirectTarget}$request_uri";
                  };
                }
              else if siteCfg.staticRoot != null then
                # Static site: serve files
                {
                  ${siteCfg.location} = {
                    tryFiles = "$uri $uri/ =404";
                    extraConfig = ''
                      # Enable caching for static assets
                      location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
                        expires 1y;
                        add_header Cache-Control "public, immutable";
                      }
                    '';
                  };
                }
              else
                # Reverse proxy
                {
                  ${siteCfg.location} = {
                    proxyPass = siteCfg.proxyPass;
                    extraConfig = ''
                      # required when the target is also TLS server with multiple hosts
                      proxy_ssl_server_name on;
                      # required when the server wants to use HTTP Authentication
                      proxy_pass_header Authorization;
                    ''
                    + optionalString siteCfg.enableSSLVerify ''
                      proxy_ssl_verify on;
                    ''
                    + optionalString (siteCfg.extraConfig != "") ''
                      ${siteCfg.extraConfig}
                    '';
                  };
                };

            extraConfig = ''
              # Use prometheus log format for metrics collection
              # All requests (HTTP and HTTPS) log to /var/log/nginx/access.log
              # which is parsed by nginxlog-exporter
              access_log /var/log/nginx/access.log prometheus;
              error_log /var/log/nginx/${name}.error error;
            '';
          }
          // optionalAttrs (siteCfg.provisionCert && !siteCfg.isDefault) {
            sslCertificate = "/var/lib/acme/${name}/cert.pem";
            sslCertificateKey = "/var/lib/acme/${name}/key.pem";
          }
        ) enabledSites;
      };
      security.acme = {
        acceptTerms = true;
        defaults.email = cfg.acme.email;
        certs = mapAttrs (name: siteCfg: {
          dnsProvider = cfg.acme.dnsProvider;
          environmentFile = config.sops.secrets.${cfg.acme.credentialsSecret}.path;
          extraDomainNames = siteCfg.extraDomainNames;
          webroot = null; # Explicitly disable webroot for DNS-01 challenge
        }) (filterAttrs (_: siteCfg: siteCfg.provisionCert) enabledSites);
      };

      # Override ACME service environment variables for sites with custom zone IDs
      systemd.services = mapAttrs' (
        name: siteCfg:
        nameValuePair "acme-${name}" {
          serviceConfig = mkIf (siteCfg.route53HostedZoneId != null) {
            Environment = [ "AWS_HOSTED_ZONE_ID=${siteCfg.route53HostedZoneId}" ];
          };
        }
      ) (filterAttrs (_: siteCfg: siteCfg.provisionCert) enabledSites);

      users.users.nginx.extraGroups = [ "acme" ];
      sops.secrets.${cfg.acme.credentialsSecret} = {
        owner = "acme";
        group = "acme";
      };
      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
    };
}
