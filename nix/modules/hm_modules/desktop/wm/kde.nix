#
# To generate a json of current config run the following command
#   nix run github:pjones/plasma-manager
#
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.wm.kde;
in
{
  options.hmFoundry.desktop.wm.kde = {
    enable = mkEnableOption "kde";
  };

  config = mkIf cfg.enable {
    programs.plasma = {
      enable = true;

      workspace = {
        colorScheme = "BreezeDark";
        lookAndFeel = "org.kde.breezedark.desktop";
      };

      startup.startupScript."foot-terminal" = {
        text = "foot";
        priority = 1;
      };

      panels = [
        {
          location = "bottom";
          hiding = "autohide";
          widgets = [
            "org.kde.plasma.kickoff"
            "org.kde.plasma.icontasks"
            "org.kde.plasma.marginsseparator"
            "org.kde.plasma.systemtray"
            "org.kde.plasma.digitalclock"
          ];
        }
      ];

      window-rules = [
        {
          description = "Foot terminal - fullscreen without titlebar";
          match = {
            window-class = {
              value = "foot";
              type = "substring";
            };
          };
          apply = {
            noborder = {
              value = true;
              apply = "force";
            };
            maximizehoriz = {
              value = true;
              apply = "initially";
            };
            maximizevert = {
              value = true;
              apply = "initially";
            };
          };
        }
      ];

      shortcuts = {
        "org.kde.spectacle.desktop"."RectangularRegionScreenShot" = "F20";
      };

      configFile = {
        "baloofilerc"."Basic Settings"."Indexing-Enabled".value = false;
        "kwinrc"."NightColor"."Active".value = true;
        "kwinrc"."NightColor"."NightTemperature".value = 2400;
        "kwinrc"."NightColor"."Mode".value = 1; # Manual location
        "kwinrc"."NightColor"."LatitudeFixed".value = "40.14";
        "kwinrc"."NightColor"."LongitudeFixed".value = "-74.44";

        # Compositor power efficiency settings
        "kwinrc"."Compositing"."GLCore".value = true; # Use OpenGL core profile
        "kwinrc"."Compositing"."LatencyControl".value = "ForceMinLatency"; # Reduce latency
        "kwinrc"."Compositing"."MaxFPS".value = 60; # Cap framerate to save power
      };
    };
  };
}
