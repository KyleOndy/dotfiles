{
  lib,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.navidrome;
  metricsPath = "/metrics";
in
{
  options.systemFoundry.navidrome = {
    enable = mkEnableOption ''
      Batteries included wrapper for Navidrome
    '';

    domainName = mkOption {
      type = types.str;
      description = "Domain to serve navidrome under";
    };

    musicFolder = mkOption {
      type = types.str;
      default = "/mnt/storage/media/music";
      description = "Path to the music library";
    };

    port = mkOption {
      type = types.port;
      default = 4533;
      description = "Port for navidrome";
    };
  };

  config = mkIf cfg.enable {
    services.navidrome = {
      enable = true;
      settings = {
        MusicFolder = cfg.musicFolder;
        Address = "127.0.0.1";
        Port = cfg.port;
        Prometheus = {
          Enabled = true;
          MetricsPath = metricsPath;
        };
      };
    };

    systemFoundry.caddyReverseProxy.sites."${cfg.domainName}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          # Navidrome serves metrics on its app port, so every vhost proxying
          # it, the public alias included, would publish them.
          extraCaddyConfig = "respond ${metricsPath}* 404";
        };
  };
}
