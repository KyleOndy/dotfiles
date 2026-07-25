{
  lib,
  pkgs,
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

    externalLibraryPaths = mkOption {
      type = types.listOf types.path;
      default = [ ];
      example = [ "/mnt/photos/personal/photos/archive" ];
      description = ''
        Directories holding an Immich External Library. Each is remounted
        read-only inside the Immich services, so Immich can index the photos
        but cannot write .xmp sidecars or delete originals.

        Immich has no application-level read-only mode: the `library` table
        carries no such flag, and upstream documents the Docker `:ro` mount
        as the only way to "disallow the images from being deleted in the web
        UI, or adding metadata to the library". This option is that `:ro`,
        expressed for the native NixOS module.

        These paths must also be listed as Import Paths on a library in the
        Immich admin UI. Setting one here only constrains Immich's access to
        it, it does not create the library.
      '';
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

      # settings = null means all configuration is done through the web UI.
      # That includes creating an External Library and setting its import
      # paths, which have no NixOS option. List those same paths in
      # externalLibraryPaths above to hold Immich to read-only access.
      # Run Immich >= v2.4.0 before pointing an external library at it:
      # earlier versions have a permanent-delete bug for offline assets
      # (immich-app/immich#24354). Check the version in the web UI footer
      # and bump the nixpkgs/immich pin if needed.
      settings = null;

      database = {
        enable = true;
        createDB = true;

        # Pin the vector backend explicitly rather than relying on stateVersion
        # defaults. On hosts with stateVersion < 25.11 (e.g. tiger at 21.11) the
        # module defaults enableVectors (pgvecto.rs) to true, which trips an
        # assertion against PostgreSQL 17+ and installs a `vectors` schema that
        # VectorChord-era dumps don't use. Immich uses VectorChord going forward.
        # NOTE: nixpkgs master removed both options (mkRemovedOptionModule); drop
        # these lines when bumping to a nixpkgs that no longer defines them.
        enableVectors = false;
        enableVectorChord = true;
      };

      redis.enable = true;
    };

    # Immich enables PostgreSQL; pin the package explicitly so it doesn't follow
    # the host stateVersion default. tiger (stateVersion 21.11) would otherwise
    # select postgresql_13, which is removed from nixpkgs.
    services.postgresql.package = pkgs.postgresql_17;

    # Ensure the mediaLocation directory exists with correct ownership.
    # The upstream NixOS immich module uses a tmpfiles `e` rule (adjust existing),
    # not `d` (create), so we must create it ourselves.
    systemd.tmpfiles.rules = [
      "d '${cfg.mediaLocation}' 0700 immich immich -"
    ];

    # Enforce read-only access to external libraries in the service sandbox.
    # systemd remounts these paths read-only inside each unit's mount
    # namespace, so the kernel refuses writes no matter what Immich attempts
    # or what the POSIX permissions would otherwise permit. This is the
    # declarative equivalent of Docker's `:ro`, and unlike a file ACL it does
    # not depend on the immich user staying outside the owning group.
    #
    # RequiresMountsFor is the safety interlock, not a convenience. Immich
    # trashes assets whose files have gone missing, so if the dataset backing
    # a library fails to mount, a scan would sweep the entire library into the
    # trash. Refusing to start is the safe failure.
    systemd.services.immich-server = mkIf (cfg.externalLibraryPaths != [ ]) {
      serviceConfig.ReadOnlyPaths = cfg.externalLibraryPaths;
      unitConfig.RequiresMountsFor = cfg.externalLibraryPaths;
    };

    systemd.services.immich-machine-learning =
      mkIf (cfg.externalLibraryPaths != [ ] && config.services.immich.machine-learning.enable)
        {
          serviceConfig.ReadOnlyPaths = cfg.externalLibraryPaths;
          unitConfig.RequiresMountsFor = cfg.externalLibraryPaths;
        };

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
