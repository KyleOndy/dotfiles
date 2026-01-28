# AWS development tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.aws;
in
{
  options.hmFoundry.dev.aws = {
    enable = mkEnableOption "AWS development tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      awscli2
    ];

    programs.zsh.initContent = ''
      # AWS CLI completion requires bashcompinit for bash-style completers
      autoload -Uz bashcompinit && bashcompinit
      complete -C '${pkgs.awscli2}/bin/aws_completer' aws
    '';
  };
}
