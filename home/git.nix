{ pkgs, ... }:

let
  old_dots = import ./_dotfiles-dir.nix;

in
{
  programs.git = {
    enable = true;
    package = pkgs.gitAndTools.gitFull; # all the tools
  };
  xdg = {
    # todo: move this into home-manager configuration
    configFile."git/config".source = old_dots + /git/config;
    configFile."git/message.txt".source = old_dots + /git/message.txt;
  };

  home.packages = with pkgs;
    [
      gitAndTools.pre-commit # manage git precommit hooks
    ];
}
