{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.input.karabiner;

  # The Kensington Expert Trackball, matched by USB vendor/product ID. Every
  # rule below is gated on this, so they stay inert when it is not connected,
  # including hotplug when docking.
  kensingtonDevice = {
    vendor_id = 1149; # Kensington
    product_id = 4128; # Expert Mouse/Trackball (0x1020)
  };

  mkTrackballManipulator = from: to: {
    type = "basic";
    inherit from to;
    conditions = [
      {
        type = "device_if";
        identifiers = [ kensingtonDevice ];
      }
    ];
  };

  # OS-wide keys are left mac-native on purpose. Karabiner here only reshapes
  # trackball buttons, which macOS gives us no other way to remap.
  kensingtonExpertRule = {
    description = "Kensington Expert Trackball Button Remapping";
    manipulators = [
      # Both bottom buttons together -> middle click. Must stay first; Karabiner
      # evaluates manipulators in order and this one claims the chord.
      (mkTrackballManipulator {
        simultaneous = [
          { pointing_button = "button1"; }
          { pointing_button = "button2"; }
        ];
        simultaneous_options = {
          key_down_order = "insensitive";
          key_up_order = "insensitive";
        };
      } [ { pointing_button = "button3"; } ])
      # Top-left button -> region screenshot (Shottr)
      (mkTrackballManipulator { pointing_button = "button3"; } [
        {
          key_code = "4";
          modifiers = [
            "left_command"
            "left_shift"
          ];
        }
      ])
      # Top-right button -> fullscreen screenshot (Shottr)
      (mkTrackballManipulator { pointing_button = "button4"; } [
        {
          key_code = "3";
          modifiers = [
            "left_command"
            "left_shift"
          ];
        }
      ])
      # Bottom-left button -> left click, so it still works on its own after the
      # chord rule above has claimed it.
      (mkTrackballManipulator { pointing_button = "button1"; } [
        { pointing_button = "button1"; }
      ])
    ];
  };

  # Keys that exist on PC keyboards and that macOS does nothing with. These fill
  # a gap rather than override a mac default, so they survive the otherwise
  # mac-native stance: Insert is absent from Apple keyboards, making this inert
  # unless an external PC keyboard is attached.
  pcKeyboardRule = {
    description = "PC keyboard keys macOS ignores";
    manipulators = [
      # Shift+Insert -> paste, the PC/Linux convention
      {
        type = "basic";
        from = {
          key_code = "insert";
          modifiers = {
            mandatory = [ "shift" ];
          };
        };
        to = [
          {
            key_code = "v";
            modifiers = [ "left_command" ];
          }
        ];
      }
    ];
  };

  # Win+E muscle memory. Unlike the rule above this one does override mac
  # defaults, deliberately: Cmd+E is Eject in Finder and "Use Selection for
  # Find" in text fields, and both are given up here.
  finderRule = {
    description = "Cmd+E opens Finder";
    manipulators = [
      {
        type = "basic";
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
      }
    ];
  };

  # Push to talk for a domestique ride. The key cannot live inside pi: its
  # extension API surfaces key names through ctx.ui.custom() and never a
  # key-down paired with a key-up, so a hold is only expressible out here.
  #
  # Karabiner owns the two edges and the watcher owns the microphone. The file
  # between them is the entire protocol, which is what makes toggle a one-line
  # change: flip the file in `to` instead of setting it here and clearing it on
  # release.
  pushToTalkRule = {
    description = "Push to talk for domestique";
    manipulators = [
      {
        type = "basic";
        from = {
          key_code = cfg.pushToTalk.key;
        };
        to = [ { shell_command = "${pkgs.coreutils}/bin/touch ${cfg.pushToTalk.file}"; } ];
        to_after_key_up = [ { shell_command = "${pkgs.coreutils}/bin/rm -f ${cfg.pushToTalk.file}"; } ];
      }
    ];
  };

  karabinerConfig = {
    profiles = [
      {
        name = "Default";
        selected = true;
        virtual_hid_keyboard = {
          keyboard_type_v2 = cfg.keyboardType;
        };
        complex_modifications = {
          rules = [
            kensingtonExpertRule
            pcKeyboardRule
            finderRule
          ]
          ++ optional cfg.pushToTalk.enable pushToTalkRule;
        };
        devices = [
          {
            identifiers = kensingtonDevice // {
              is_pointing_device = true;
            };
            ignore = false;
            manipulate_caps_lock_led = false;
          }
        ];
      }
    ];
  };

  karabinerConfigJson = builtins.toJSON karabinerConfig;
in
{
  options.hmFoundry.desktop.input.karabiner = {
    enable = mkEnableOption "Karabiner-Elements configuration";

    keyboardType = mkOption {
      type = types.enum [
        "ansi"
        "iso"
        "jis"
      ];
      default = "ansi";
      description = "Keyboard type for virtual HID keyboard";
    };

    pushToTalk = {
      enable = mkEnableOption "hold a key to record a domestique utterance";

      key = mkOption {
        type = types.str;
        default = "caps_lock";
        description = ''
          Key held to record. It has to be one pi's TUI never reads and one a
          hand can find on the bars without looking, which caps_lock is.

          The rule carries no application condition, so the key stops toggling
          caps everywhere and not only during a ride. Outside one it creates
          and removes a file nobody reads.
        '';
      };

      file = mkOption {
        type = types.str;
        default = "${config.home.homeDirectory}/.pi/domestique/listening";
        description = ''
          Path that exists while the key is held. The domestique watcher polls
          for it and opens the microphone; nothing else reads it.
        '';
      };
    };
  };

  config = mkIf (pkgs.stdenv.isDarwin && cfg.enable) {
    home.file.".config/karabiner/karabiner.json" = {
      text = karabinerConfigJson;
      force = true;
    };

    # Note: Karabiner-Elements itself should be installed via Homebrew.
    # See each darwin host's configuration.nix homebrew.casks.
  };
}
