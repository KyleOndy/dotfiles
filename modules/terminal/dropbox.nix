{ lib, config, ... }:
with lib;
let cfg = config.foundry.terminal.dropbox;
in
{
  options.foundry.terminal.dropbox = {
    enable = mkEnableOption "dropbox";
  };
  config = mkIf cfg.enable {
    #services = {
    #  dropbox.enable = true;
    #};
  };
}
