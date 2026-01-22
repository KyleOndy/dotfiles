{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.input.karabiner;

  # Karabiner configuration for Kensington Expert Trackball
  kensingtonExpertConfig = {
    profiles = [
      {
        name = "Default";
        selected = true;
        complex_modifications = {
          rules = [
            {
              description = "Kensington Expert Trackball Button Remapping";
              manipulators = [
                # Bottom-left button (button3) -> Left click (button1)
                {
                  type = "basic";
                  from = {
                    pointing_button = "button3";
                  };
                  to = [
                    {
                      pointing_button = "button1";
                    }
                  ];
                  conditions = [
                    {
                      type = "device_if";
                      identifiers = [
                        {
                          vendor_id = 1149; # Kensington
                          product_id = 32794; # Expert Trackball
                        }
                      ];
                    }
                  ];
                }
                # Bottom-right button (button4) -> Right click (button3)
                {
                  type = "basic";
                  from = {
                    pointing_button = "button4";
                  };
                  to = [
                    {
                      pointing_button = "button3";
                    }
                  ];
                  conditions = [
                    {
                      type = "device_if";
                      identifiers = [
                        {
                          vendor_id = 1149;
                          product_id = 32794;
                        }
                      ];
                    }
                  ];
                }
                # Top-left button (button1) -> Region screenshot (cmd+shift+4)
                {
                  type = "basic";
                  from = {
                    pointing_button = "button1";
                  };
                  to = [
                    {
                      key_code = "4";
                      modifiers = [
                        "left_command"
                        "left_shift"
                      ];
                    }
                  ];
                  conditions = [
                    {
                      type = "device_if";
                      identifiers = [
                        {
                          vendor_id = 1149;
                          product_id = 32794;
                        }
                      ];
                    }
                  ];
                }
                # Top-right button (button2) -> Middle click (unchanged, but explicit)
                # This is optional since button2 is already middle click by default
              ];
            }
          ];
        };
      }
    ];
  };

  karabinerConfigJson = builtins.toJSON kensingtonExpertConfig;
in
{
  options.hmFoundry.desktop.input.karabiner = {
    enable = mkEnableOption "Karabiner-Elements configuration";

    kensingtonExpert = {
      enable = mkEnableOption "Kensington Expert Trackball button remapping";
    };
  };

  config = mkIf (pkgs.stdenv.isDarwin && cfg.enable) {
    # Only create config if Kensington Expert is enabled
    home.file.".config/karabiner/karabiner.json" = mkIf cfg.kensingtonExpert.enable {
      text = karabinerConfigJson;
    };

    # Note: Karabiner-Elements itself should be installed via Homebrew
    # See work-mac configuration.nix for the homebrew.casks configuration
  };
}
