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

  # Push to talk for a domestique ride. The keys cannot live inside pi: its
  # extension API surfaces key names through ctx.ui.custom() and never a
  # key-down paired with a key-up, so a hold is only expressible out here.
  #
  # Karabiner owns the edges and the watchers own the microphone. The files
  # between them are the entire protocol, which is what makes toggle a one-line
  # change: flip the file in `to` instead of setting it here and clearing it on
  # release.
  listeningFile = "${cfg.pushToTalk.root}/listening";
  replayFile = "${cfg.pushToTalk.root}/replay";
  outOfBandFile = "${cfg.pushToTalk.root}/outofband";

  heldWhile = file: {
    to = [ { shell_command = "${pkgs.coreutils}/bin/touch ${file}"; } ];
    to_after_key_up = [ { shell_command = "${pkgs.coreutils}/bin/rm -f ${file}"; } ];
  };

  pushToTalkRule = {
    description = "Push to talk for domestique";
    manipulators = [
      (
        {
          type = "basic";
          from.key_code = cfg.pushToTalk.key;
        }
        // heldWhile listeningFile
      )
    ];
  };

  # The pad (keyboard/domestique-pad) emits three bare F-keys and nothing else,
  # the third of them a QMK combo of the other two. Each rule is gated on the
  # device, so an F13 from any other keyboard cannot open the microphone.
  mkPadManipulator =
    key: actions:
    {
      type = "basic";
      from.key_code = key;
      conditions = [
        {
          type = "device_if";
          identifiers = [
            {
              vendor_id = cfg.pushToTalk.pad.vendorId;
              product_id = cfg.pushToTalk.pad.productId;
            }
          ];
        }
      ];
    }
    // actions;

  padRule = {
    description = "domestique pad";
    manipulators = [
      (mkPadManipulator "f13" (heldWhile listeningFile))
      # A byte per press rather than a touch. The watcher polls at 0.1s and a
      # tap lands entirely between two polls, so what has to accumulate on disk
      # is the count, not the file's existence.
      (mkPadManipulator "f16" {
        to = [ { shell_command = "${pkgs.coreutils}/bin/printf . >> ${replayFile}"; } ];
      })
      (mkPadManipulator "f17" (heldWhile outOfBandFile))
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
          ++ optional cfg.pushToTalk.enable pushToTalkRule
          ++ optional (cfg.pushToTalk.enable && cfg.pushToTalk.pad.enable) padRule;
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

      root = mkOption {
        type = types.str;
        default = "${config.home.homeDirectory}/.pi/domestique";
        description = ''
          Directory the key files are written into: `listening` while channel
          one is held, `outofband` while the pad chord is held, and `replay`,
          which accumulates one byte per replay tap. The domestique watchers
          poll for them; nothing else reads them.
        '';
      };

      pad = {
        enable = mkEnableOption "the two-key domestique pad (keyboard/domestique-pad)";

        vendorId = mkOption {
          type = types.ints.unsigned;
          default = 65261;
          description = ''
            USB vendor of the pad, matched per rule so an F13 from any other
            keyboard cannot open the microphone. 65261 is 0xFEED, declared in
            keyboard/domestique-pad/keyboard.json.

            What has to match is what macOS enumerates rather than what the
            firmware asks for. Karabiner-EventViewer reports it, and a mismatch
            leaves every pad rule inert with nothing anywhere saying so.
          '';
        };

        productId = mkOption {
          type = types.ints.unsigned;
          default = 53349;
          description = ''
            USB product of the pad. 53349 is 0xD065, declared alongside the
            vendor. Arbitrary, but it has to be unusual: 0xFEED is the vendor
            every hand-wired QMK board uses, so a common product id here would
            match somebody else's keyboard as well as this one.
          '';
        };
      };
    };
  };

  config = mkIf (pkgs.stdenv.isDarwin && cfg.enable) {
    assertions = [
      {
        assertion =
          !cfg.pushToTalk.enable || cfg.pushToTalk.root == "${config.home.homeDirectory}/.pi/domestique";
        message = ''
          hmFoundry.desktop.input.karabiner.pushToTalk.root is polled by
          domestique-listen.py, domestique-tts.py and extensions/domestique.ts,
          each of which resolves it under ~/.pi/domestique, and the domestique
          wrappers export DOMESTIQUE_ROOT over anything set in the environment.
          Any other path leaves the keys touching files nothing reads: no cue,
          no tint, no recording, and nothing anywhere reporting a fault.
        '';
      }
    ];

    home.file.".config/karabiner/karabiner.json" = {
      text = karabinerConfigJson;
      force = true;
    };

    # Note: Karabiner-Elements itself should be installed via Homebrew.
    # See each darwin host's configuration.nix homebrew.casks.
  };
}
