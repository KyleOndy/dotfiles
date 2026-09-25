{
  lib,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.alloy;

  alloyMap =
    attrs: "{ " + concatStringsSep ", " (mapAttrsToList (n: v: ''${n} = "${v}"'') attrs) + " }";

  # Interpolating a multi-line string into an indented one does not re-indent
  # it, so this block lands flush left in the generated file.
  basicAuthBlock = optionalString (cfg.basicAuth != null) ''

    basic_auth {
      username      = "${cfg.basicAuth.username}"
      password_file = "${toString cfg.basicAuth.passwordFile}"
    }'';
in
{
  options.systemFoundry.monitoringStack.alloy = {
    enable = mkEnableOption "Grafana Alloy for log shipping to Loki";

    lokiUrl = mkOption {
      type = types.str;
      description = "Loki push URL";
      example = "https://loki.tiger.infra.ondy.org/loki/api/v1/push";
    };

    basicAuth = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            username = mkOption {
              type = types.str;
              description = "Basic auth username";
            };
            passwordFile = mkOption {
              type = types.path;
              description = "Path to file containing the basic auth password";
            };
          };
        }
      );
      default = null;
      description = "Basic auth credentials for Loki push (Caddy hosts)";
    };

    extraLabels = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Labels stamped on every stream at write time, journal and
        `extraConfig` sources alike.
      '';
      example = {
        host = "tiger";
        environment = "production";
      };
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Alloy components appended to the generated config. Forward them to
        `loki.write.default.receiver`.
      '';
      example = ''
        loki.source.file "jellyfin" {
          targets    = [{ __path__ = "/var/lib/jellyfin/log/*.log", job = "jellyfin" }]
          forward_to = [loki.write.default.receiver]
        }
      '';
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    # The module runs alloy under DynamicUser, so log access is granted by
    # supplementary group rather than by a static user's extraGroups. The
    # list merges with the module's own "systemd-journal".
    systemd.services.alloy.serviceConfig.SupplementaryGroups =
      optional config.services.jellyfin.enable "media" ++ optional config.services.caddy.enable "caddy";

    services.alloy = {
      enable = true;
      # Alloy phones home a component inventory to Grafana on startup unless
      # told not to. https://grafana.com/docs/alloy/latest/data-collection/
      extraFlags = [ "--disable-reporting" ];
    };

    environment.etc."alloy/config.alloy".text = ''
      loki.write "default" {
        endpoint {
          url = "${cfg.lokiUrl}"${basicAuthBlock}
        }
        external_labels = ${alloyMap cfg.extraLabels}
      }

      discovery.relabel "journal" {
        targets = []

        rule {
          source_labels = ["__journal__systemd_unit"]
          target_label  = "unit"
        }

        rule {
          source_labels = ["__journal__hostname"]
          target_label  = "hostname"
        }

        rule {
          source_labels = ["__journal_priority_keyword"]
          target_label  = "level"
        }
      }

      loki.source.journal "journal" {
        max_age       = "12h"
        labels        = { job = "systemd-journal" }
        relabel_rules = discovery.relabel.journal.rules
        forward_to    = [loki.write.default.receiver]
      }

      ${cfg.extraConfig}
    '';
  };
}
