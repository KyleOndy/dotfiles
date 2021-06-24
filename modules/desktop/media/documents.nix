{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.desktop.media.documents;
in
{
  options.foundry.desktop.media.documents = {
    enable = mkEnableOption "documents";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      libreoffice # getting things done
      zathura # lightweight PDF viewer
    ];
  };
}
