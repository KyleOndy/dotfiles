{ pkgs, ... }:

let
  old_dots = import ./_dotfiles-dir.nix;

in
{
  home.packages = with pkgs; [
    gnupg # for email and git
    pinentry-curses # cli pin entry
  ];

  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 1800;
    enableSshSupport = true;
    pinentryFlavor = "curses"; # emacs?
  };

  xdg = {
    # todo: move this into home-manager configuration
    configFile."gnupg/gpg.conf".source = old_dots + /gnupg/gpg.conf;
  };
}
