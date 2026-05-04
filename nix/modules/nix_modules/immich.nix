{
  lib,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.immich;
in
{
  options.systemFoundry.immich = {
    enable = mkEnableOption "Batteries included wrapper for Immich (self-hosted photo management)";

    domainName = mkOption {
      type = types.str;
      description = "Domain to serve Immich under";
    };

    provisionCert = mkOption {
      type = types.bool;
      default = false;
      description = "Provision SSL certificate for this service";
    };

    mediaLocation = mkOption {
      type = types.path;
      default = "/mnt/storage/photos";
      description = "Directory for Immich media storage (photos, thumbnails, encoded video). Must be writable by the immich user.";
    };

    port = mkOption {
      type = types.port;
      default = 2283;
      description = "Port for the Immich server";
    };
  };

  config = mkIf cfg.enable {
    services.immich = {
      enable = true;
      host = "127.0.0.1";
      port = cfg.port;
      mediaLocation = cfg.mediaLocation;

      # Allow ffmpeg to use the iGPU for hardware-accelerated video transcoding.
      # No conflict with Jellyfin: Jellyfin uses the media engines (VQE/SFC),
      # Immich uses fixed-function decode only. Both share /dev/dri/renderD128 safely.
      accelerationDevices = [ "/dev/dri/renderD128" ];

      machine-learning.enable = true;

      # settings = null means all configuration is done through the web UI
      settings = null;

      database = {
        enable = true;
        createDB = true;
      };

      redis.enable = true;
    };

    # Ensure the mediaLocation directory exists with correct ownership.
    # The upstream NixOS immich module uses a tmpfiles `e` rule (adjust existing),
    # not `d` (create), so we must create it ourselves.
    systemd.tmpfiles.rules = [
      "d '${cfg.mediaLocation}' 0700 immich immich -"
    ];

    # Grant the immich user access to the iGPU device
    users.users.immich.extraGroups = [
      "render"
      "video"
    ];

    systemFoundry.caddyReverseProxy.sites."${cfg.domainName}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          provisionCert = cfg.provisionCert;
          # Disable response buffering for upload progress streaming
          flushInterval = "-1";
          # Large video uploads and ML processing can take a while
          proxyTimeout = "600s";
        };

    systemFoundry.nginxReverseProxy.sites."${cfg.domainName}" =
      mkIf (config.systemFoundry.nginxReverseProxy.enable)
        {
          enable = true;
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          provisionCert = cfg.provisionCert;
        };
  };
}
