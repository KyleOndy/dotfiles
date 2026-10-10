{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.loki;

  # Alerting stays in vmalert; these only mint series for it. Range equals
  # interval to tile evaluations: the alert's 26h span would rescan a day of
  # chunks every 5 minutes.
  rulesYaml = ''
    groups:
      # vector(1) scans no chunks, so this is free, and it is the only series
      # here that exists when nothing is wrong. Its absence is what proves the
      # ruler and its remote_write are still alive.
      - name: ruler_heartbeat
        interval: 1m
        rules:
          - record: loki:ruler_heartbeat
            expr: vector(1)
            labels:
              host: ${config.networking.hostName}

      - name: ytdl_sub_logs
        interval: 5m
        rules:
          # Counts refusals not videos (yt-dlp retries); match avoids the U+2019.
          - record: ytdl_sub:bot_blocked_lines:count5m
            expr: |
              sum by (host) (
                count_over_time({unit="ytdl-sub-youtube.service"} |= "Sign in to confirm you" [5m])
              )

      # audio-language-check runs inside Radarr and Sonarr, which journal its
      # stderr under their own units. Its logger copy carries no unit label.
      - name: audio_language_logs
        interval: 5m
        rules:
          - record: audio_language:review_lines:count5m
            expr: |
              sum by (host, unit) (
                count_over_time({unit=~"radarr.service|sonarr.service"} |= "audio-language-check: REVIEW " [5m])
              )

      # One line every 5 minutes per source that analysed any audio, none for
      # one that analysed none. A stream with no name in its config logs its
      # URL minus userinfo, and a Protect URL's path is the stream credential.
      # https://github.com/tphakala/birdnet-go/blob/30197a29859303db226f2d8d68146f2b3b3c0490/internal/analysis/processor/pipeline_stats.go#L109-L131
      - name: birdnet_logs
        interval: 5m
        rules:
          - record: birdnet:pipeline_stats_reports:count5m
            expr: |
              sum by (host, source) (
                count_over_time({unit="birdnet-go.service"} |= "operation=pipeline_stats_report"
                  | logfmt source
                  | label_format source=`{{ if contains "://" .source }}unnamed{{ else }}{{ .source }}{{ end }}` [5m])
              )

      # cogsworth exports nothing about its mail channel, but mulog writes
      # one JSON line per message outcome and one per agent completion.
      # Nothing logs a successful reply: answered is accepted minus
      # agent-failed. usage.cost is OpenRouter's charge in USD.
      - name: cogsworth_mail_logs
        interval: 5m
        rules:
          - record: cogsworth_mail:events:count5m
            expr: |
              sum by (host, event) (
                count_over_time({unit="cogsworth.service"} |~ "cogsworth\\.(mail\\.[a-z]+|agent\\.core)/"
                  | json event=`["mulog/event-name"]` [5m])
              )
          - record: cogsworth_mail:agent_tokens:sum5m
            expr: |
              sum by (host, model) (
                sum_over_time({unit="cogsworth.service"} |= "cogsworth.agent.core/completion"
                  | json model, tokens=`usage.total_tokens` | unwrap tokens [5m])
              )
          - record: cogsworth_mail:agent_cost_usd:sum5m
            expr: |
              sum by (host, model) (
                sum_over_time({unit="cogsworth.service"} |= "cogsworth.agent.core/completion"
                  | json model, cost=`usage.cost` | unwrap cost [5m])
              )
  '';

  # auth_enabled = false pins every stream to the "fake" tenant, and the local
  # rule store keys by tenant, so rules have to sit one directory down.
  ruleDir = pkgs.linkFarm "loki-rules" [
    {
      name = "fake/recording.yaml";
      path = pkgs.writeText "loki-recording-rules.yaml" rulesYaml;
    }
  ];
in
{
  options.systemFoundry.monitoringStack.loki = {
    enable = mkEnableOption "Loki log aggregation";

    port = mkOption {
      type = types.port;
      default = 3100;
      description = "Port for Loki HTTP API";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen on";
    };

    retentionPeriod = mkOption {
      type = types.int;
      default = parentCfg.retention.logs;
      description = "Days to retain logs (defaults to parent retention.logs)";
    };

    domain = mkOption {
      type = types.str;
      default = "loki.${parentCfg.domain}";
      description = "Domain name for Loki (defaults to loki.{parent domain})";
    };

    alertmanagerUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:9093";
      description = ''
        Alertmanager the ruler notifies. Loopback, which is what lets it skip
        the basic auth Caddy puts in front of the Alertmanager UI.
      '';
    };

    remoteWriteUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:8428/api/v1/write";
      description = "Where the ruler ships recording rule samples";
    };

    instanceInterfaceNames = mkOption {
      type = types.listOf types.str;
      default = [
        "eno1"
        "lo"
      ];
      description = "Network interfaces for Loki ring discovery";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    services.loki = {
      enable = true;
      extraFlags = map (
        iface: "-common.storage.ring.instance-interface-names=${iface}"
      ) cfg.instanceInterfaceNames;
      configuration = {
        # Run in single-process mode (all-in-one)
        target = "all";

        server.http_listen_port = cfg.port;
        server.http_listen_address = cfg.listenAddress;
        server.log_level = "warn";

        auth_enabled = false;

        memberlist = {
          bind_addr = [ "127.0.0.1" ];
        };

        common = {
          instance_interface_names = cfg.instanceInterfaceNames;
          ring = {
            kvstore = {
              store = "inmemory";
            };
          };
          replication_factor = 1;
        };

        ingester = {
          lifecycler = {
            address = "127.0.0.1";
            ring = {
              kvstore = {
                store = "inmemory";
              };
              replication_factor = 1;
            };
          };
          chunk_retain_period = "1m";
        };

        schema_config = {
          configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
        };

        storage_config = {
          tsdb_shipper = {
            active_index_directory = "/var/lib/loki/tsdb-index";
            cache_location = "/var/lib/loki/tsdb-cache";
          };
          filesystem = {
            directory = "/var/lib/loki/chunks";
          };
        };

        limits_config = {
          reject_old_samples = true;
          reject_old_samples_max_age = "168h";
          retention_period = "${toString cfg.retentionPeriod}d";
          max_query_series = 5000;
          # The span of a range query (default 30d1h) and the [range] inside
          # any query (default unlimited) both stop at 45 days. Unbounded, a
          # [400d] reads every chunk until query_timeout and holds a querier
          # slot of the four meanwhile. offset still reaches further back.
          max_query_length = "45d";
          max_query_range = "45d";
        };

        table_manager = {
          retention_deletes_enabled = true;
          retention_period = "${toString cfg.retentionPeriod}d";
        };

        compactor = {
          working_directory = "/var/lib/loki/compactor";
          compaction_interval = "10m";
          retention_enabled = true;
          retention_delete_delay = "2h";
          retention_delete_worker_count = 150;
          delete_request_store = "filesystem";
        };

        ruler = {
          storage = {
            type = "local";
            local.directory = ruleDir;
          };

          # Scratch space, created by loki itself under its own state dir.
          rule_path = "/var/lib/loki/ruler";

          alertmanager_url = cfg.alertmanagerUrl;
          enable_alertmanager_v2 = true;
          enable_api = true;

          ring.kvstore.store = "inmemory";

          remote_write = {
            enabled = true;
            clients.victoriametrics.url = cfg.remoteWriteUrl;
          };
        };
      };
    };

    # Basic auth on every path: the query and admin APIs (delete, rules,
    # flush) are as dangerous as push. Grafana and the ruler use loopback.
    systemFoundry.caddyReverseProxy.sites."${cfg.domain}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://${cfg.listenAddress}:${toString cfg.port}";
          basicAuth = parentCfg.monitoringBasicAuth;
        };
  };
}
