{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.shell.bash;
in
{
  options.foundry.shell.bash = {
    enable = mkEnableOption "bash";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      bash_5

      # Node packages do not appear when running `nix search`. Use
      # `nix-env -qaPA nixos.nodePackages` to view them.`
      nodePackages.bash-language-server
    ];
  };
}
