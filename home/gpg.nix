{ pkgs, ... }:

let old_dots = import ./_dotfiles-dir.nix;

in {
  home.packages = [
    pkgs.gnupg # for email and git
  ];

  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 1800;
    enableSshSupport = true;
  };

  xdg = {
    # todo: move this into home-manager configuration
    configFile."gnupg/gpg.conf".source = old_dots + /gnupg/gpg.conf;
  };
}
