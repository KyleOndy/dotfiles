{ pkgs, ... }:

{
  xsession = {
    enable = true;
    windowManager.i3 = {
      enable = true;
      config = {
        modifier = "Mod4"; # super
        workspaceAutoBackAndForth = true;
      };
    };
  };

  services.screen-locker = {
    enable = true;
    inactiveInterval = 5;
    lockCmd = "/home/tuxinaut/.config/i3/i3-exit lock";
  };
}
