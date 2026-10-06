{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.jellyfin;
  stateDir = "/var/lib/jellyfin";

  # Complete encoding.xml for Jellyfin 10.11.x. Schema captured from a
  # freshly-generated 10.11.10 encoding.xml. The hardware values describe the
  # Intel Arc A380 in tiger, the only GPU in the fleet; there is nothing to
  # parameterize until there is a second one.
  encodingXml = pkgs.writeText "jellyfin-encoding.xml" ''
    <?xml version="1.0" encoding="utf-8"?>
    <EncodingOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
      <EncodingThreadCount>-1</EncodingThreadCount>
      <EnableFallbackFont>false</EnableFallbackFont>
      <EnableAudioVbr>false</EnableAudioVbr>
      <DownMixAudioBoost>2</DownMixAudioBoost>
      <DownMixStereoAlgorithm>None</DownMixStereoAlgorithm>
      <MaxMuxingQueueSize>2048</MaxMuxingQueueSize>
      <EnableThrottling>true</EnableThrottling>
      <ThrottleDelaySeconds>180</ThrottleDelaySeconds>
      <EnableSegmentDeletion>true</EnableSegmentDeletion>
      <SegmentKeepSeconds>720</SegmentKeepSeconds>
      <HardwareAccelerationType>qsv</HardwareAccelerationType>
      <VaapiDevice>/dev/dri/renderD128</VaapiDevice>
      <QsvDevice>/dev/dri/renderD128</QsvDevice>
      <EnableTonemapping>true</EnableTonemapping>
      <EnableVppTonemapping>false</EnableVppTonemapping>
      <EnableVideoToolboxTonemapping>false</EnableVideoToolboxTonemapping>
      <TonemappingAlgorithm>bt2390</TonemappingAlgorithm>
      <TonemappingMode>auto</TonemappingMode>
      <TonemappingRange>auto</TonemappingRange>
      <TonemappingDesat>0</TonemappingDesat>
      <TonemappingPeak>100</TonemappingPeak>
      <TonemappingParam>0</TonemappingParam>
      <VppTonemappingBrightness>16</VppTonemappingBrightness>
      <VppTonemappingContrast>1</VppTonemappingContrast>
      <H264Crf>23</H264Crf>
      <H265Crf>28</H265Crf>
      <EncoderPreset xsi:nil="true" />
      <DeinterlaceDoubleRate>false</DeinterlaceDoubleRate>
      <DeinterlaceMethod>yadif</DeinterlaceMethod>
      <EnableDecodingColorDepth10Hevc>true</EnableDecodingColorDepth10Hevc>
      <EnableDecodingColorDepth10Vp9>true</EnableDecodingColorDepth10Vp9>
      <EnableDecodingColorDepth10HevcRext>true</EnableDecodingColorDepth10HevcRext>
      <EnableDecodingColorDepth12HevcRext>true</EnableDecodingColorDepth12HevcRext>
      <EnableEnhancedNvdecDecoder>true</EnableEnhancedNvdecDecoder>
      <PreferSystemNativeHwDecoder>true</PreferSystemNativeHwDecoder>
      <EnableIntelLowPowerH264HwEncoder>false</EnableIntelLowPowerH264HwEncoder>
      <EnableIntelLowPowerHevcHwEncoder>false</EnableIntelLowPowerHevcHwEncoder>
      <EnableHardwareEncoding>true</EnableHardwareEncoding>
      <AllowHevcEncoding>true</AllowHevcEncoding>
      <AllowAv1Encoding>true</AllowAv1Encoding>
      <EnableSubtitleExtraction>true</EnableSubtitleExtraction>
      <HardwareDecodingCodecs>
        <string>h264</string>
        <string>hevc</string>
        <string>mpeg2video</string>
        <string>av1</string>
        <string>vp9</string>
      </HardwareDecodingCodecs>
      <AllowOnDemandMetadataBasedKeyframeExtractionForExtensions>
        <string>mkv</string>
      </AllowOnDemandMetadataBasedKeyframeExtractionForExtensions>
    </EncodingOptions>
  '';

  # Complete network.xml for Jellyfin 10.11.x, captured from tiger's.
  # KnownProxies is the Caddy site below: without it Jellyfin ignores
  # X-Forwarded-For and sees every proxied client as 127.0.0.1, so remote
  # viewers count as local and skip remote bitrate and access limits.
  networkXml = pkgs.writeText "jellyfin-network.xml" ''
    <?xml version="1.0" encoding="utf-8"?>
    <NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
      <BaseUrl />
      <EnableHttps>false</EnableHttps>
      <RequireHttps>false</RequireHttps>
      <CertificatePath />
      <CertificatePassword />
      <InternalHttpPort>8096</InternalHttpPort>
      <InternalHttpsPort>8920</InternalHttpsPort>
      <PublicHttpPort>8096</PublicHttpPort>
      <PublicHttpsPort>8920</PublicHttpsPort>
      <AutoDiscovery>true</AutoDiscovery>
      <EnableUPnP>false</EnableUPnP>
      <EnableIPv4>true</EnableIPv4>
      <EnableIPv6>false</EnableIPv6>
      <EnableRemoteAccess>true</EnableRemoteAccess>
      <LocalNetworkSubnets />
      <LocalNetworkAddresses />
      <KnownProxies>
        <string>127.0.0.1</string>
      </KnownProxies>
      <IgnoreVirtualInterfaces>true</IgnoreVirtualInterfaces>
      <VirtualInterfaceNames>
        <string>veth</string>
      </VirtualInterfaceNames>
      <EnablePublishedServerUriByRequest>false</EnablePublishedServerUriByRequest>
      <PublishedServerUriBySubnet />
      <RemoteIPFilter />
      <IsRemoteIPFilterBlacklist>false</IsRemoteIPFilterBlacklist>
    </NetworkConfiguration>
  '';
in
{
  options.systemFoundry.jellyfin = {
    enable = mkEnableOption ''
      Batteries included wrapper for jellyfin
    '';

    group = mkOption {
      type = types.str;
      default = "jellyfin";
      description = "Group to run jellyfin under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to server jellyfin under";
    };

    backup = mkOption {
      default = { };
      description = "Automated backup via Jellyfin native backup API";
      type = types.submodule {
        options.enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable automated backup";
        };
        options.apiKeyFile = mkOption {
          type = types.path;
          description = "Path to file containing the Jellyfin API key";
        };
      };
    };

    transcodeDebugLogging = mkOption {
      type = types.bool;
      default = false;
      description = "Enable debug-level logging for transcoding operations";
    };

    installPlaybackReportingPlugin = mkOption {
      type = types.bool;
      default = false;
      description = "Automatically install the Playback Reporting plugin for play history tracking";
    };

    remoteClientBitrateLimit = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 8000000;
      description = ''
        Per-stream cap for remote clients, in bits per second. Jellyfin has no
        total across streams, so size it as upload / expected concurrent
        streams. null leaves the dashboard's value alone.
      '';
    };

    hardwareAcceleration = mkEnableOption ''
      declarative hardware-accelerated transcoding. Writes encoding.xml on every
      Jellyfin start, so Nix is the source of truth: changes made in the Playback
      dashboard revert on the next restart
    '';
  };

  config = mkIf cfg.enable {
    services.jellyfin = {
      enable = true;
      package = pkgs.jellyfin;
      group = cfg.group;
    };

    # Caddy: reverse proxy with automatic WebSocket support, 300s timeouts, and unbuffered streaming
    systemFoundry.caddyReverseProxy.sites."${cfg.domainName}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://127.0.0.1:8096";
          proxyTimeout = "300s";
          flushInterval = "-1";
          # TODO: add rate limiting on /Users/AuthenticateByName once caddy-ratelimit plugin is added
          extraCaddyConfig = ''
            encode zstd gzip

            @images path /Items/*/Images/*
            header @images Cache-Control "public, max-age=604800, immutable"
          '';
        };

    # Configure debug logging when enabled
    systemd.tmpfiles.rules = mkIf cfg.transcodeDebugLogging [
      "L+ ${stateDir}/config/logging.json - jellyfin ${cfg.group} - ${
        pkgs.writeText "jellyfin-logging.json" (
          builtins.toJSON {
            Serilog = {
              MinimumLevel = {
                Default = "Information";
                Override = {
                  Microsoft = "Warning";
                  System = "Warning";
                }
                // optionalAttrs cfg.transcodeDebugLogging {
                  "MediaBrowser.MediaEncoding.Transcoding" = "Debug";
                  "MediaBrowser.Controller.MediaEncoding" = "Debug";
                };
              };
              WriteTo = [
                {
                  Name = "Console";
                  Args = {
                    outputTemplate = "[{Timestamp:HH:mm:ss}] [{Level:u3}] [{ThreadId}] {SourceContext}: {Message:lj}{NewLine}{Exception}";
                  };
                }
                {
                  Name = "Async";
                  Args = {
                    configure = [
                      {
                        Name = "File";
                        Args = {
                          path = "%JELLYFIN_LOG_DIR%//log_.log";
                          rollingInterval = "Day";
                          retainedFileCountLimit = 3;
                          rollOnFileSizeLimit = true;
                          fileSizeLimitBytes = 100000000;
                          outputTemplate = "[{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz}] [{Level:u3}] [{ThreadId}] {SourceContext}: {Message}{NewLine}{Exception}";
                        };
                      }
                    ];
                  };
                }
              ];
              Enrich = [
                "FromLogContext"
                "WithThreadId"
              ];
            };
          }
        )
      }"
    ];

    # Relax UMask so trickplay directories are group-writable, matching the
    # other *arr services (lidarr, sonarr, etc.) that share the media group.
    systemd.services.jellyfin.serviceConfig.UMask = mkForce "0002";

    systemd.services = {
      jellyfin-backup = mkIf cfg.backup.enable {
        startAt = "*-*-* 3:00:00";
        path = with pkgs; [
          curl
          findutils
        ];
        environment = {
          API_KEY_FILE = cfg.backup.apiKeyFile;
          BACKUP_DIR = "${stateDir}/data/backups";
          RETENTION_DAYS = "30";
        };
        script = ''
          API_KEY=$(cat "$API_KEY_FILE")
          curl -sf "http://127.0.0.1:8096/Backup/Create" \
            -H "Content-Type: application/json" \
            -H "Authorization: MediaBrowser Token=$API_KEY" \
            -d '{"Database": true, "Metadata": true, "Subtitles": true, "Trickplay": false}'
          find "$BACKUP_DIR" -name "*.zip" -mtime +"$RETENTION_DAYS" -delete
        '';
        serviceConfig = {
          Type = "oneshot";
          Nice = 19;
          IOSchedulingClass = "idle";
        };
      };
      jellyfin-transcode-cleanup = {
        startAt = "*-*-* 04:00:00";
        path = with pkgs; [
          fd
        ];
        script = ''
          if [ -d "${config.services.jellyfin.cacheDir}/transcodes" ]; then
            fd --type=file --changed-before="${"6 hours"}" . ${config.services.jellyfin.cacheDir}/transcodes/ -X rm -v --
          fi
        '';
        serviceConfig = {
          Nice = 19;
          IOSchedulingClass = "idle";
        };
      };
    };

    # Apply declarative config before Jellyfin starts. Runs on every (re)start
    # so the dashboard cannot drift from the Nix-declared XML.
    systemd.services.jellyfin-config = {
      description = "Apply declarative Jellyfin config (network.xml, encoding.xml)";
      wantedBy = [ "jellyfin.service" ];
      before = [ "jellyfin.service" ];
      partOf = [ "jellyfin.service" ];
      path = with pkgs; [
        coreutils
        gnused
      ];
      script = ''
        mkdir -p ${stateDir}/config
        install -o jellyfin -g ${cfg.group} -m 0644 ${networkXml} ${stateDir}/config/network.xml
        ${optionalString cfg.hardwareAcceleration "install -o jellyfin -g ${cfg.group} -m 0644 ${encodingXml} ${stateDir}/config/encoding.xml"}
        ${optionalString (cfg.remoteClientBitrateLimit != null) ''
          # system.xml holds every other dashboard setting, so only this one
          # element is pinned. Jellyfin creates the file on first start, which
          # leaves a fresh install at 0 (no limit) until the next restart.
          if [ -f ${stateDir}/config/system.xml ]; then
            sed -i 's|<RemoteClientBitrateLimit>[0-9]*</RemoteClientBitrateLimit>|<RemoteClientBitrateLimit>${toString cfg.remoteClientBitrateLimit}</RemoteClientBitrateLimit>|' ${stateDir}/config/system.xml
            chown jellyfin:${cfg.group} ${stateDir}/config/system.xml
          fi
        ''}
        chown jellyfin:${cfg.group} ${stateDir}/config
      '';
      # No RemainAfterExit: re-run on every Jellyfin (re)start so a dashboard edit
      # never outlives a restart. partOf ties our lifecycle to jellyfin.service.
      serviceConfig = {
        Type = "oneshot";
        User = "root"; # need root to chown into the jellyfin state dir
      };
    };

    # Install Playback Reporting plugin if enabled
    systemd.services.jellyfin-install-playback-reporting = mkIf cfg.installPlaybackReportingPlugin {
      description = "Install Jellyfin Playback Reporting Plugin";
      wantedBy = [ "jellyfin.service" ];
      before = [ "jellyfin.service" ];
      path = with pkgs; [
        unzip
        curl
        coreutils
      ];
      script =
        let
          pluginDir = "${stateDir}/plugins/Jellyfin.Plugin.PlaybackReporting";
          # Using version 15.0.0.0 which is compatible with Jellyfin 10.8+
          pluginUrl = "https://github.com/jellyfin/jellyfin-plugin-playbackreporting/releases/download/15.0.0.0/playback_reporting_15.0.0.0.zip";
        in
        ''
          # Create plugins directory if it doesn't exist
          mkdir -p ${stateDir}/plugins

          # Only install if not already present
          if [ ! -d "${pluginDir}" ]; then
            echo "Installing Playback Reporting plugin..."

            # Download plugin
            curl -L -o /tmp/playback_reporting.zip "${pluginUrl}"

            # Create plugin directory
            mkdir -p "${pluginDir}"

            # Extract plugin
            unzip -o /tmp/playback_reporting.zip -d "${pluginDir}"

            # Clean up
            rm /tmp/playback_reporting.zip

            # Set ownership
            chown -R jellyfin:${cfg.group} "${pluginDir}"

            echo "Playback Reporting plugin installed successfully"
          else
            echo "Playback Reporting plugin already installed"
          fi
        '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root"; # Need root to chown
      };
    };
  };
}
