# Document processing and writing tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.documents;
in
{
  options.hmFoundry.dev.documents = {
    enable = mkEnableOption "Document processing and writing tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      aspell
      aspellDicts.en
      aspellDicts.en-computers
      aspellDicts.en-science
      proselint
      dos2unix
      ispell
    ];
  };
}
