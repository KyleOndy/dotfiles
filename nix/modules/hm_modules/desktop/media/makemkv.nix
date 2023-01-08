{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.desktop.media.makemkv;
in
{
  options.hmFoundry.desktop.media.makemkv = {
    enable = mkEnableOption "makemkv";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      makemkv # rip DVDs
    ];
  };
}
