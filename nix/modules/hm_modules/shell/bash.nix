{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.shell.bash;
in
{
  options.hmFoundry.shell.bash = {
    enable = mkEnableOption "bash";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      bashInteractive

      # Node packages do not appear when running `nix search`. Use
      # `nix-env -qaPA nixos.nodePackages` to view them.`
      nodePackages.bash-language-server
    ];
    programs.bash = {
      enable = true;
      initExtra = '''';
      bashrcExtra = ''
        export PS4='+ \D{%s}: ''${BASH_SOURCE:-}:''${FUNCNAME[0]:-}:L''${LINENO:-}: '
      '';
    };
  };
}
