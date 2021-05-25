{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.terminal.tmux;
in
{
  options.foundry.terminal.tmux = {
    enable = mkEnableOption "todo";
  };

  config = mkIf cfg.enable {
    # stuff goes here
  };
}
