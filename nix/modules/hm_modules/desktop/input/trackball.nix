{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.input.trackball;

  # evsieve command for Kensington Expert button remapping
  # Button mapping:
  # - button272 (BTN_LEFT, top-left) -> KEY_F20 (mapped to screenshot in KDE)
  # - button273 (BTN_RIGHT, top-right) -> button274 (BTN_MIDDLE, middle click)
  # - button274 (BTN_MIDDLE, bottom-left) -> button272 (BTN_LEFT, left click)
  # - button275 (BTN_SIDE, bottom-right) -> button273 (BTN_RIGHT, right click)
  evsieveCommand =
    let
      devicePath = cfg.kensingtonExpert.devicePath;
    in
    ''
      ${pkgs.evsieve}/bin/evsieve \
        --input ${devicePath} \
        --map btn:left key:f20 \
        --map btn:middle btn:left \
        --map btn:side btn:right \
        --map btn:right btn:middle \
        --output
    '';
in
{
  options.hmFoundry.desktop.input.trackball = {
    enable = mkEnableOption "trackball input configuration";

    kensingtonExpert = {
      enable = mkEnableOption "Kensington Expert Trackball button remapping";

      devicePath = mkOption {
        type = types.str;
        default = "/dev/input/by-id/usb-Kensington_Expert_Wireless_TB-event-mouse";
        description = ''
          Device path for the Kensington Expert Trackball.
          Find the correct path by running:
          ls /dev/input/by-id/ | grep -i kensington

          Or test button codes with:
          sudo evtest /dev/input/by-id/<device-name>
        '';
      };
    };
  };

  config = mkIf (pkgs.stdenv.isLinux && cfg.enable && cfg.kensingtonExpert.enable) {
    # Systemd user service for button remapping via evsieve
    systemd.user.services.kensington-remap = {
      Unit = {
        Description = "Kensington Expert Trackball button remapping";
        After = [ "graphical-session.target" ];
        # Only start if the device exists
        ConditionPathExists = cfg.kensingtonExpert.devicePath;
      };

      Service = {
        Type = "simple";
        ExecStart = evsieveCommand;
        Restart = "on-failure";
        RestartSec = "5s";
        # Allow access to input devices
        # Note: User needs to be in 'input' group
      };

      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };

    # Ensure required packages are installed
    home.packages = with pkgs; [
      evsieve # Button remapping tool
      evtest # Useful for debugging button codes
      spectacle # KDE screenshot tool
    ];
  };
}
