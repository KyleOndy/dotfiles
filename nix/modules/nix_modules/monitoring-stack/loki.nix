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
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    services.loki = {
      enable = true;
      configuration = {
        server.http_listen_port = cfg.port;
        server.http_listen_address = cfg.listenAddress;

        auth_enabled = false;

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
          chunk_idle_period = "3m";
          chunk_block_size = 262144;
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
        };
      };
    };
  };
}
