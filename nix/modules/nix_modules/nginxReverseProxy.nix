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
          default = false;
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

        clientMaxBodySize = "512m";

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
        '';
        virtualHosts = lib.attrsets.mapAttrs
          (name: cfg: {
            enableACME = cfg.provisionCert;
            forceSSL = true;

            # todo: should I make the path configurable?
            sslCertificate = "/var/lib/acme/${name}/cert.pem";
            sslCertificateKey = "/var/lib/acme/${name}/key.pem";
            locations."/" = {
              proxyPass = cfg.proxyPass;
              # todo: these may need to be configurable
              extraConfig = ''
                # required when the target is also TLS server with multiple hosts
                proxy_ssl_server_name on;
                # required when the server wants to use HTTP Authentication
                proxy_pass_header Authorization;
                proxy_ssl_verify on;
              '';
            };
            extraConfig = ''
              access_log /var/log/nginx/${name}.access upstreamlog;
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
