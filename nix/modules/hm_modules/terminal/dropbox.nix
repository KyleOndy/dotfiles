{ lib, config, ... }:
with lib;
let cfg = config.hmFoundry.terminal.dropbox;
in
{
  options.hmFoundry.terminal.dropbox = {
    enable = mkEnableOption "dropbox";
  };
  config = mkIf cfg.enable {
    #services = {
    #  dropbox.enable = true;
    #};
  };
}
