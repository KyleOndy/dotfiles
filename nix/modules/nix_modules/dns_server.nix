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
    # dnsmasq wasn't working until I re-ran nixos-rebuild switch
    # https://serverfault.com/a/907603
    systemd.services.dnsmasq = {
      after = [ "network-online.target" "network.target" "systemd-resolved.service" ];
      wants = [ "network-online.target" ];
    };

    services.dnsmasq = {
      enable = true;
      alwaysKeepRunning = true;
      settings = {
        log-async = 25;
        log-queries = true;

        # TODO: check that conf-file does what I expect
        conf-file = optional cfg.blacklist.enable cfg.blacklist.path;

        address = optionals (cfg.aRecords != { }) (
          (builtins.attrValues (builtins.mapAttrs
            (n: v: "/${n}/${v}")
            cfg.aRecords
          ))
        );

        cname = optionals (cfg.cnameRecords != { }) (
          (builtins.attrValues (builtins.mapAttrs
            (n: v: "${n},${v}")
            cfg.cnameRecords
          ))
        );

        server = optionals (cfg.domainRecords != { }) (
          (builtins.attrValues (builtins.mapAttrs
            (n: v: "/${n}/${v}")
            cfg.domainRecords
          ))
        );
      };
    };


    # if this files doesn't exist, dnsmasq fails to start. The preStart config
    # is appended to the preStart already defined for dnsmasq, so we don't need
    # to worry about breaking any of that.
    systemd.services.dnsmasq.preStart = ''
      mkdir -p $(dirname ${cfg.blacklist.path})
      touch ${cfg.blacklist.path}
    '';

    # TODO: dnsmasq needs to be restarted to use this list. systemd's `PartOf`
    #       annotation looks promising
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
