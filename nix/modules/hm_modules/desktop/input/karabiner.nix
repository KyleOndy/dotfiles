{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.input.karabiner;

  # App bundle ID lists for conditional rules
  terminalApps = [
    "^com\\.apple\\.Terminal$"
    "^com\\.googlecode\\.iterm2$"
    "^co\\.zeit\\.hyperterm$"
    "^co\\.zeit\\.hyper$"
    "^io\\.alacritty$"
    "^net\\.kovidgoyal\\.kitty$"
  ];

  browserApps = [
    "^org\\.mozilla\\.firefox$"
    "^com\\.google\\.Chrome$"
    "^com\\.apple\\.Safari$"
    "^com\\.microsoft\\.Edge"
    "^com\\.brave\\.Browser$"
  ];

  # Helper functions for generating Karabiner rules
  mkExclusionCondition = apps: {
    type = "frontmost_application_unless";
    bundle_identifiers = apps;
  };

  mkInclusionCondition = apps: {
    type = "frontmost_application_if";
    bundle_identifiers = apps;
  };

  mkManipulator =
    {
      from,
      to,
      conditions ? [ ],
    }:
    {
      type = "basic";
      inherit from to;
    }
    // optionalAttrs (conditions != [ ]) { inherit conditions; };

  # Kensington Expert Trackball rules
  kensingtonExpertRules = mkIf cfg.kensingtonExpert.enable [
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
      ];
    }
  ];

  # PC-style core shortcuts (Ctrl+C/V/X/Z/etc. → Cmd equivalents)
  # Excluded in terminals to preserve Ctrl+C as SIGINT
  pcCoreShortcuts = mkIf (cfg.pcStyle.enable && cfg.pcStyle.coreShortcuts.enable) [
    {
      description = "PC-style core shortcuts (Ctrl → Cmd)";
      manipulators =
        let
          mkShortcut =
            key: to:
            mkManipulator {
              from = {
                key_code = key;
                modifiers = {
                  mandatory = [ "control" ];
                };
              };
              to = [ to ];
              conditions = [ (mkExclusionCondition terminalApps) ];
            };
        in
        [
          (mkShortcut "c" {
            key_code = "c";
            modifiers = [ "left_command" ];
          }) # Copy
          (mkShortcut "v" {
            key_code = "v";
            modifiers = [ "left_command" ];
          }) # Paste
          (mkShortcut "x" {
            key_code = "x";
            modifiers = [ "left_command" ];
          }) # Cut
          (mkShortcut "z" {
            key_code = "z";
            modifiers = [ "left_command" ];
          }) # Undo
          (mkShortcut "y" {
            key_code = "z";
            modifiers = [
              "left_command"
              "left_shift"
            ];
          }) # Redo
          (mkShortcut "a" {
            key_code = "a";
            modifiers = [ "left_command" ];
          }) # Select All
          (mkShortcut "s" {
            key_code = "s";
            modifiers = [ "left_command" ];
          }) # Save
          (mkShortcut "n" {
            key_code = "n";
            modifiers = [ "left_command" ];
          }) # New
          (mkShortcut "t" {
            key_code = "t";
            modifiers = [ "left_command" ];
          }) # New Tab
          (mkShortcut "f" {
            key_code = "f";
            modifiers = [ "left_command" ];
          }) # Find
          (mkShortcut "g" {
            key_code = "g";
            modifiers = [ "left_command" ];
          }) # Find Next
          (mkShortcut "o" {
            key_code = "o";
            modifiers = [ "left_command" ];
          }) # Open
          (mkShortcut "w" {
            key_code = "w";
            modifiers = [ "left_command" ];
          }) # Close Window
          (mkShortcut "b" {
            key_code = "b";
            modifiers = [ "left_command" ];
          }) # Bold
          (mkShortcut "i" {
            key_code = "i";
            modifiers = [ "left_command" ];
          }) # Italic
          (mkShortcut "u" {
            key_code = "u";
            modifiers = [ "left_command" ];
          }) # Underline
          (mkShortcut "k" {
            key_code = "k";
            modifiers = [ "left_command" ];
          }) # Insert Link
          (mkShortcut "r" {
            key_code = "r";
            modifiers = [ "left_command" ];
          }) # Reload
          # F5 -> Cmd+R (Reload)
          (mkManipulator {
            from = {
              key_code = "f5";
            };
            to = [
              {
                key_code = "r";
                modifiers = [ "left_command" ];
              }
            ];
            conditions = [ (mkExclusionCondition terminalApps) ];
          })
        ];
    }
  ];

  # PC-style navigation (Ctrl+Arrows, Home/End)
  pcNavigation = mkIf (cfg.pcStyle.enable && cfg.pcStyle.navigation.enable) [
    {
      description = "PC-style navigation";
      manipulators =
        let
          mkNav =
            key: to:
            mkManipulator {
              from = key;
              to = [ to ];
              conditions = [ (mkExclusionCondition terminalApps) ];
            };
        in
        [
          # Ctrl+Left -> Option+Left (word left)
          (mkNav
            {
              key_code = "left_arrow";
              modifiers = {
                mandatory = [ "control" ];
              };
            }
            {
              key_code = "left_arrow";
              modifiers = [ "left_option" ];
            }
          )
          # Ctrl+Right -> Option+Right (word right)
          (mkNav
            {
              key_code = "right_arrow";
              modifiers = {
                mandatory = [ "control" ];
              };
            }
            {
              key_code = "right_arrow";
              modifiers = [ "left_option" ];
            }
          )
          # Ctrl+Up -> Cmd+Up (document start)
          (mkNav
            {
              key_code = "up_arrow";
              modifiers = {
                mandatory = [ "control" ];
              };
            }
            {
              key_code = "up_arrow";
              modifiers = [ "left_command" ];
            }
          )
          # Ctrl+Down -> Cmd+Down (document end)
          (mkNav
            {
              key_code = "down_arrow";
              modifiers = {
                mandatory = [ "control" ];
              };
            }
            {
              key_code = "down_arrow";
              modifiers = [ "left_command" ];
            }
          )
          # Ctrl+Backspace -> Option+Backspace (delete word)
          (mkNav
            {
              key_code = "delete_or_backspace";
              modifiers = {
                mandatory = [ "control" ];
              };
            }
            {
              key_code = "delete_or_backspace";
              modifiers = [ "left_option" ];
            }
          )
          # Home -> Cmd+Left (line start)
          (mkNav { key_code = "home"; } {
            key_code = "left_arrow";
            modifiers = [ "left_command" ];
          })
          # End -> Cmd+Right (line end)
          (mkNav { key_code = "end"; } {
            key_code = "right_arrow";
            modifiers = [ "left_command" ];
          })
          # Ctrl+Home -> Cmd+Up (document start)
          (mkNav
            {
              key_code = "home";
              modifiers = {
                mandatory = [ "control" ];
              };
            }
            {
              key_code = "up_arrow";
              modifiers = [ "left_command" ];
            }
          )
          # Ctrl+End -> Cmd+Down (document end)
          (mkNav
            {
              key_code = "end";
              modifiers = {
                mandatory = [ "control" ];
              };
            }
            {
              key_code = "down_arrow";
              modifiers = [ "left_command" ];
            }
          )
        ];
    }
  ];

  # PC-style app switching (Alt+Tab, Alt+F4)
  pcAppSwitching = mkIf (cfg.pcStyle.enable && cfg.pcStyle.appSwitching.enable) [
    {
      description = "PC-style app switching";
      manipulators = [
        # Alt+Tab -> Cmd+Tab (switch apps forward)
        (mkManipulator {
          from = {
            key_code = "tab";
            modifiers = {
              mandatory = [ "option" ];
            };
          };
          to = [
            {
              key_code = "tab";
              modifiers = [ "left_command" ];
            }
          ];
        })
        # Alt+Shift+Tab -> Cmd+Shift+Tab (switch apps backward)
        (mkManipulator {
          from = {
            key_code = "tab";
            modifiers = {
              mandatory = [
                "option"
                "shift"
              ];
            };
          };
          to = [
            {
              key_code = "tab";
              modifiers = [
                "left_command"
                "left_shift"
              ];
            }
          ];
        })
        # Alt+F4 -> Cmd+Q (quit app)
        (mkManipulator {
          from = {
            key_code = "f4";
            modifiers = {
              mandatory = [ "option" ];
            };
          };
          to = [
            {
              key_code = "q";
              modifiers = [ "left_command" ];
            }
          ];
        })
      ];
    }
  ];

  # Browser-specific controls (only in browsers)
  pcBrowserControls = mkIf (cfg.pcStyle.enable && cfg.pcStyle.browserControls.enable) [
    {
      description = "PC-style browser controls";
      manipulators =
        let
          mkBrowser =
            from: to:
            mkManipulator {
              inherit from to;
              conditions = [ (mkInclusionCondition browserApps) ];
            };
        in
        [
          # Ctrl+L -> Cmd+L (address bar)
          (mkBrowser
            {
              key_code = "l";
              modifiers = {
                mandatory = [ "control" ];
              };
            }
            [
              {
                key_code = "l";
                modifiers = [ "left_command" ];
              }
            ]
          )
          # Ctrl+- -> Cmd+- (zoom out)
          (mkBrowser
            {
              key_code = "hyphen";
              modifiers = {
                mandatory = [ "control" ];
              };
            }
            [
              {
                key_code = "hyphen";
                modifiers = [ "left_command" ];
              }
            ]
          )
          # Ctrl+= -> Cmd+= (zoom in)
          (mkBrowser
            {
              key_code = "equal_sign";
              modifiers = {
                mandatory = [ "control" ];
              };
            }
            [
              {
                key_code = "equal_sign";
                modifiers = [ "left_command" ];
              }
            ]
          )
          # Ctrl+0 -> Cmd+0 (reset zoom)
          (mkBrowser
            {
              key_code = "0";
              modifiers = {
                mandatory = [ "control" ];
              };
            }
            [
              {
                key_code = "0";
                modifiers = [ "left_command" ];
              }
            ]
          )
          # Alt+Left -> Cmd+Left (back)
          (mkBrowser
            {
              key_code = "left_arrow";
              modifiers = {
                mandatory = [ "option" ];
              };
            }
            [
              {
                key_code = "left_arrow";
                modifiers = [ "left_command" ];
              }
            ]
          )
          # Alt+Right -> Cmd+Right (forward)
          (mkBrowser
            {
              key_code = "right_arrow";
              modifiers = {
                mandatory = [ "option" ];
              };
            }
            [
              {
                key_code = "right_arrow";
                modifiers = [ "left_command" ];
              }
            ]
          )
        ];
    }
  ];

  # System shortcuts (PrintScreen, lock, task manager)
  pcSystemShortcuts = mkIf (cfg.pcStyle.enable && cfg.pcStyle.systemShortcuts.enable) [
    {
      description = "PC-style system shortcuts";
      manipulators = [
        # PrintScreen -> Cmd+Shift+4 (region screenshot)
        (mkManipulator {
          from = {
            key_code = "print_screen";
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
        })
        # Shift+PrintScreen -> Cmd+Shift+4 (region screenshot)
        (mkManipulator {
          from = {
            key_code = "print_screen";
            modifiers = {
              mandatory = [ "shift" ];
            };
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
        })
        # Cmd+L -> Ctrl+Cmd+Q (lock screen)
        (mkManipulator {
          from = {
            key_code = "l";
            modifiers = {
              mandatory = [ "command" ];
            };
          };
          to = [
            {
              key_code = "q";
              modifiers = [
                "left_control"
                "left_command"
              ];
            }
          ];
        })
        # Ctrl+Esc -> Launchpad
        (mkManipulator {
          from = {
            key_code = "escape";
            modifiers = {
              mandatory = [ "control" ];
            };
          };
          to = [
            {
              # Open Launchpad
              shell_command = "open -a Launchpad";
            }
          ];
        })
        # Ctrl+Shift+Esc -> Activity Monitor
        (mkManipulator {
          from = {
            key_code = "escape";
            modifiers = {
              mandatory = [
                "control"
                "shift"
              ];
            };
          };
          to = [
            {
              shell_command = "open -a 'Activity Monitor'";
            }
          ];
        })
        # Cmd+E -> Open Finder
        (mkManipulator {
          from = {
            key_code = "e";
            modifiers = {
              mandatory = [ "command" ];
            };
          };
          to = [
            {
              shell_command = "open -a Finder";
            }
          ];
        })
      ];
    }
  ];

  # Combine all rules based on enabled options
  allRules = flatten [
    kensingtonExpertRules
    pcCoreShortcuts
    pcNavigation
    pcAppSwitching
    pcBrowserControls
    pcSystemShortcuts
  ];

  # Generate the final Karabiner configuration
  karabinerConfig = {
    profiles = [
      {
        name = "Default";
        selected = true;
        complex_modifications = {
          rules = allRules;
        };
      }
    ];
  };

  karabinerConfigJson = builtins.toJSON karabinerConfig;
in
{
  options.hmFoundry.desktop.input.karabiner = {
    enable = mkEnableOption "Karabiner-Elements configuration";

    kensingtonExpert = {
      enable = mkEnableOption "Kensington Expert Trackball button remapping";
    };

    pcStyle = {
      enable = mkEnableOption "PC-style keyboard shortcuts";

      coreShortcuts = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable core PC shortcuts (Ctrl+C/V/X/Z/etc. → Cmd equivalents)";
        };
      };

      navigation = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable PC-style navigation (Ctrl+Arrows, Home/End)";
        };
      };

      appSwitching = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable PC-style app switching (Alt+Tab, Alt+F4)";
        };
      };

      browserControls = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable PC-style browser controls (Ctrl+L, zoom, etc.)";
        };
      };

      systemShortcuts = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable PC-style system shortcuts (PrintScreen, lock, task manager)";
        };
      };
    };
  };

  config = mkIf (pkgs.stdenv.isDarwin && cfg.enable) {
    # Create Karabiner config if any feature is enabled
    home.file.".config/karabiner/karabiner.json" = mkIf (
      cfg.kensingtonExpert.enable || cfg.pcStyle.enable
    ) { text = karabinerConfigJson; };

    # Note: Karabiner-Elements itself should be installed via Homebrew
    # See work-mac configuration.nix for the homebrew.casks configuration
  };
}
