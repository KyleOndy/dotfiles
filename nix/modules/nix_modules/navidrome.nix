{
  lib,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.navidrome;
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
      };
    };

    systemFoundry.caddyReverseProxy.sites."${cfg.domainName}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
        };
  };
}
