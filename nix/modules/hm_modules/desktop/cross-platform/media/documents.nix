{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.media.documents;
in
{
  options.hmFoundry.desktop.media.documents = {
    enable = mkEnableOption "documents";
  };

  config = mkIf cfg.enable {
    home.packages =
      with pkgs;
      [
        hunspell # spell check
        hunspellDicts.en-us-large
        zathura # lightweight PDF viewer
      ]
      ++ lib.optionals pkgs.stdenv.isLinux [
        libreoffice # getting things done - Not supported on macOS
      ];
  };
}
