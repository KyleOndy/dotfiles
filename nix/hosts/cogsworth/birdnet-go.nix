# BirdNET-Go listens to the outdoor Protect cameras' RTSP audio and
# classifies bird song into its own SQLite database. Nothing reads it yet;
# its web UI is the proof, reached with `ssh -L 8090:127.0.0.1:8090
# cogsworth`. The pi's own I2S mic is not a source: it is indoors and the
# voice listener owns it.
{ config, pkgs, ... }:
let
  stateDir = "/var/lib/birdnet-go";
  configFile = "${stateDir}/config.yaml";
in
{
  # Full rtsps:// URL of each camera channel to listen to. The path segment
  # is the stream credential, so the whole URL is the secret.
  sops.secrets.birdnet_rtsp_url_porch = {
    owner = "birdnet";
  };
  sops.secrets.birdnet_rtsp_url_front_door = {
    owner = "birdnet";
  };

  # The whole config is a template because the stream URL and the
  # coordinates are secrets. Keys left out take upstream defaults.
  sops.templates."birdnet-go-config" = {
    owner = "birdnet";
    # The unit references the rendered file by its stable path, so a change
    # to it alone would not restart anything.
    restartUnits = [ "birdnet-go.service" ];
    content = ''
      main:
        name: Cogsworth birds
      birdnet:
        latitude: ${config.sops.placeholder.weather_lat}
        longitude: ${config.sops.placeholder.weather_lon}
        locale: en-us
      realtime:
        audio:
          # No sound card: the only source is the stream below.
          sources: []
          export:
            enabled: true
            path: clips/
            type: wav
            # Clips are outdoor audio of whoever is in the yard, kept only
            # long enough to review what a detection actually was.
            retention:
              policy: age
              maxage: 7d
        rtsp:
          streams:
            - name: Porch
              url: ${config.sops.placeholder.birdnet_rtsp_url_porch}
              enabled: true
              type: rtsp
              transport: tcp
              models: [birdnet]
            - name: Front Door
              url: ${config.sops.placeholder.birdnet_rtsp_url_front_door}
              enabled: true
              type: rtsp
              transport: tcp
              models: [birdnet]
        privacyfilter:
          enabled: true
          # The "Human non-vocal" class scores 0.1 to 0.35 on doors, cars and
          # wind with the yard empty; speech at either mic scores well above.
          confidence: 0.5
        birdweather:
          enabled: false
      webserver:
        enabled: true
        port: "8090"
      output:
        sqlite:
          enabled: true
          path: birdnet.db
    '';
  };

  users.users.birdnet = {
    isSystemUser = true;
    group = "birdnet";
  };
  users.groups.birdnet = { };

  systemd.services.birdnet-go = {
    description = "BirdNET-Go bird song classifier";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # ffmpeg pulls the RTSP stream; sox renders spectrograms in the UI.
    path = [
      pkgs.ffmpeg-headless
      pkgs.sox
    ];
    serviceConfig = {
      User = "birdnet";
      Group = "birdnet";
      StateDirectory = "birdnet-go";
      WorkingDirectory = stateDir;
      # The UI's settings page writes back to its config file, so the
      # rendered template is copied rather than read in place. The Nix
      # copy wins on every restart.
      ExecStartPre = "${pkgs.coreutils}/bin/install -m 0600 ${
        config.sops.templates."birdnet-go-config".path
      } ${configFile}";
      ExecStart = "${pkgs.birdnet-go}/bin/birdnet-go serve --config ${configFile}";
      Restart = "always";
      RestartSec = "10s";
      # A ceiling, not a budget: the classifier and two audio-only ffmpegs
      # sit well under it. No-op while the host's memory cgroup controller is off.
      MemoryMax = "1G";

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      CapabilityBoundingSet = "";
    };
  };
}
