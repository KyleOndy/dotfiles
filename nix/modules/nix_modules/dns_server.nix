{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.dnsServer;
in
{
  # todo: submodules?
  options.systemFoundry.dnsServer = {
    enable = mkEnableOption ''
      Fully featured DNS server.
    '';

    blacklist = mkOption {
      default = { };
      description = "Download and apply blocklist";
      type = types.submodule {
        options.enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable blacklist";
        };
        options.path = mkOption {
          type = types.path;
          default = "/srv/dnsmasq/dnsmasq.blacklist.txt";
          description = ''
            Specifies the file path the blacklist will be downloaded to.
          '';
        };
        options.source = mkOption {
          type = types.str;
          default = "https://raw.githubusercontent.com/notracking/hosts-blocklists/master/dnsmasq/dnsmasq.blacklist.txt";
          description = ''
            Specifies the URL the blacklist will be downloaded from.
          '';
        };
      };
    };
    aRecords = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "A records to provision on DNS server";
      example = ''
        { "foo.bar.org" = "1.2.3.4"; }
      '';
    };
    cnameRecords = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "CNAME records to provision on DNS server";
      example = ''
        { "foo.bar.org" = "biz.baz"; }
      '';
    };
    domainRecords = mkOption {
      # todo: need a better name
      type = types.attrsOf types.str;
      default = { };
      description = "Where to forward DNS lookups for that domain";
      example = ''
        { "dmz.foo.bar" = "5.6.7.8"; }
      '';
    };
    upstreamDnsServers = mkOption {
      type = types.listOf types.str;
      default = [ "9.9.9.9" "149.112.112.112" ]; # quad nine
      description = "Servers to use for upstream lookups";
    };
  };

  config = mkIf cfg.enable {
    services.dnsmasq = {
      enable = true;
      servers = cfg.upstreamDnsServers;
      extraConfig = ''
          ${optionalString (cfg.aRecords != {}) ''
          ${builtins.concatStringsSep "\n"
                (builtins.attrValues (builtins.mapAttrs
                  (n: v: "address=/${n}/${v}")
                  cfg.aRecords
                )
                )}
        ''}

          ${optionalString (cfg.cnameRecords != {}) ''
          ${builtins.concatStringsSep "\n"
                (builtins.attrValues (builtins.mapAttrs
                (n: v: "cname=${n},${v}")
                cfg.cnameRecords
                )
                )}
        ''}
          ${optionalString (cfg.domainRecords != {}) ''
          ${builtins.concatStringsSep "\n"
                (builtins.attrValues (builtins.mapAttrs
                (n: v: "server=/${n}/${v}")
                cfg.domainRecords
                )
                )}
        ''}

          ${optionalString cfg.blacklist.enable ''
                conf-file=${cfg.blacklist.path}
          ''
        }
      '';
    };


    # if this files doesn't exist, dnsmasq fails to start. The preStart config
    # is appended to the preStart already defined for dnsmasq, so we don't need
    # to worry about breaking any of that.
    systemd.services.dnsmasq.preStart = ''
      mkdir -p $(dirname ${cfg.blacklist.path})
      touch ${cfg.blacklist.path}
    '';

    systemd.services.dnsmasq_blocklist = {
      startAt = "*-*-* 02:00:00";
      script = ''
        ${pkgs.curl}/bin/curl \
        -sS \
        --create-dirs \
        -O \
        --output-dir $(dirname ${cfg.blacklist.path}) \
        ${cfg.blacklist.source}
        echo "Downloaded blocklist"
      '';

    };

    networking.firewall.allowedTCPPorts = [ 53 ];
    networking.firewall.allowedUDPPorts = [ 53 ];
  };
}
