{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.dev.nix;
in
{
  options.foundry.dev.nix = {
    enable = mkEnableOption "todo";
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
