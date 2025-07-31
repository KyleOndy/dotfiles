{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.wm.i3;
in
{
  options.hmFoundry.desktop.wm.i3 = {
    enable = mkEnableOption "i3";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [ brightnessctl ];
    xsession = {
      enable = true;
      windowManager.i3 = {
        enable = true;
        config = {
          modifier = "Mod4"; # super
          workspaceAutoBackAndForth = true;
          keybindings = lib.mkOptionDefault {
            "XF86AudioMute" = "exec amixer set Master toggle";
            "XF86AudioLowerVolume" = "exec amixer set Master 4%-";
            "XF86AudioRaiseVolume" = "exec amixer set Master 4%+";
            "XF86MonBrightnessDown" = "exec brightnessctl set 4%-";
            "XF86MonBrightnessUp" = "exec brightnessctl set 4%+";
            #"${modifier}+Shift+x" = "exec systemctl suspend";
          };
          startup = [
            {
              command = "exec i3-msg workspace 1";
              always = true;
              notification = false;
            }
          ];
        };
      };
    };

    services.screen-locker = {
      enable = true;
      inactiveInterval = 5;
      lockCmd = "/home/tuxinaut/.config/i3/i3-exit lock";
    };
  };
}
