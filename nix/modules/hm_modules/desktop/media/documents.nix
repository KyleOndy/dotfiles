{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.desktop.media.documents;
in
{
  options.hmFoundry.desktop.media.documents = {
    enable = mkEnableOption "documents";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      hunspell # spell check
      hunspellDicts.en-us-large
      libreoffice # getting things done
      zathura # lightweight PDF viewer
    ];
  };
}
