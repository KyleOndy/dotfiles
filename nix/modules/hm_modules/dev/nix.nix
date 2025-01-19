{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.dev.nix;
in
{
  options.hmFoundry.dev.nix = {
    enable = mkEnableOption "nix";
  };

  config = mkIf cfg.enable {
    programs.neovim = {
      plugins = with pkgs.vimPlugins;
        [
          vim-nix # https://github.com/LnL7/vim-nix
        ];
    };
  };
}
