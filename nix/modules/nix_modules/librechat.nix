{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.librechat;

  configFile = pkgs.writeText "librechat.yaml" (
    builtins.toJSON {
      version = "1.2.1";
      cache = true;
      endpoints = {
        custom = [
          {
            name = "OpenRouter";
            apiURL = "https://openrouter.ai/api/v1/chat/completions";
            baseURL = "https://openrouter.ai/api/v1";
            models = {
              fetch = true;
            };
            titleConvo = true;
            titleModel = "openrouter/auto";
            modelDisplayLabel = "OpenRouter";
          }
        ];
      };
    }
  );
in
{
  options.systemFoundry.librechat = {
    enable = mkEnableOption "LibreChat - self-hosted AI chat frontend";

    port = mkOption {
      type = types.port;
      default = 3080;
      description = "Port for LibreChat to listen on";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address for LibreChat to bind to";
    };
  };

  config = mkIf cfg.enable {
    services.mongodb = {
      enable = true;
      bind_ip = "127.0.0.1";
    };

    sops.secrets = {
      librechat_jwt_secret.mode = "0400";
      librechat_jwt_refresh_secret.mode = "0400";
      librechat_creds_key.mode = "0400";
      librechat_creds_iv.mode = "0400";
      librechat_openrouter_api_key.mode = "0400";
    };

    sops.templates."librechat-env" = {
      content = ''
        HOST=${cfg.host}
        PORT=${toString cfg.port}
        MONGO_URI=mongodb://127.0.0.1:27017/LibreChat
        DOMAIN_CLIENT=http://localhost:${toString cfg.port}
        DOMAIN_SERVER=http://localhost:${toString cfg.port}
        NO_INDEX=true
        ALLOW_REGISTRATION=true
        ALLOW_UNVERIFIED_EMAIL_LOGIN=true
        JWT_SECRET=${config.sops.placeholder.librechat_jwt_secret}
        JWT_REFRESH_SECRET=${config.sops.placeholder.librechat_jwt_refresh_secret}
        CREDS_KEY=${config.sops.placeholder.librechat_creds_key}
        CREDS_IV=${config.sops.placeholder.librechat_creds_iv}
        OPENROUTER_API_KEY=${config.sops.placeholder.librechat_openrouter_api_key}
        CONFIG_PATH=${configFile}
      '';
    };

    systemd.services.librechat = {
      description = "LibreChat AI chat frontend";
      after = [
        "network.target"
        "mongodb.service"
      ];
      requires = [ "mongodb.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.librechat}/bin/librechat-server";
        EnvironmentFile = config.sops.templates."librechat-env".path;
        WorkingDirectory = "/var/lib/librechat";
        StateDirectory = "librechat";

        DynamicUser = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        PrivateTmp = true;
        NoNewPrivileges = true;

        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
