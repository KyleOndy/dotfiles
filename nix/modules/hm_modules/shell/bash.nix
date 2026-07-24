{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.shell.bash;

  # PS4 is what bash prints in front of each traced line under `set -x`. The
  # default is a bare "+", which tells you nothing about where you are; this
  # adds an epoch timestamp, source file, function, and line number.
  #
  # Kept in the store rather than inline in .bashrc because BASH_ENV below
  # points at it, and BASH_ENV fires for every non-interactive bash. A path
  # under $HOME breaks the moment bash runs somewhere $HOME is not readable:
  # pi's sandbox denies reads outside $PWD and ~/.pi, so pointing BASH_ENV at
  # ~/.bashrc printed "Operation not permitted" twice on every pi startup and
  # once at the head of every bash tool result the agent read. /nix/store
  # stays readable in that sandbox, so a store path just works.
  #
  # see `man bash` for available expansions
  # https://news.ycombinator.com/item?id=27617128
  bashPs4 = pkgs.writeText "bash-ps4.sh" ''
    export PS4='+ \D{%s}: ''${BASH_SOURCE:-}:''${FUNCNAME[0]:-}:L''${LINENO:-}: '
  '';
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
    # BASH_ENV is read by non-interactive bash only, so it is what gives
    # scripts the PS4 above (.bashrc handles the interactive case). It lives
    # here rather than in the zsh config because nothing about it is
    # zsh-specific: any shell that launches a bash script wants it set.
    #
    # Worth knowing that this sources a file on every single bash script
    # invocation, which is why it points at one line of PS4 and nothing else.
    home.sessionVariables.BASH_ENV = "${bashPs4}";

    programs.bash = {
      enable = true;
      initExtra = "";
      bashrcExtra = ''
        . ${bashPs4}
      '';
    };
  };
}
