{ lib, pkgs, config, ... }:
with lib;
let
  cfg = config.foundry.dev.python;
  python-packages = python-packages: with python-packages; [ virtualenv ];
  system-python-with-packages = pkgs.python3.withPackages python-packages;
in
{
  options.foundry.dev.python = {
    enable = mkEnableOption "python";
  };

  config = mkIf cfg.enable {
    home.packages = [ system-python-with-packages ];

    programs.neovim = {
      plugins = with pkgs.vimPlugins; [
        {
          plugin = jedi-vim;
        }
      ];
    };
  };
}
