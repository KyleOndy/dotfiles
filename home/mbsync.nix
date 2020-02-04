# mbsync
{ pkgs, ... }:

let
  old_dots = import ./_dotfiles-dir.nix;

in
{
  services.mbsync = {
    enable = true;
    configFile = ~/.config/mbsync/mbsyncrc;
  };

  xdg = { configFile."mbsync/mbsyncrc".source = old_dots + /mbsync/mbsyncrc; };
}
