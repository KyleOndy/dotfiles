{ pkgs, ... }:

let old_dots = import ./_dotfiles-dir.nix;

in {
  home.packages = [
    pkgs.gnupg            # for email and git
    pkgs.pinentry         # cli pin entry
  ];

  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 1800;
    enableSshSupport = true;
    extraConfig = "pinentry-program ${pkgs.pinentry}/bin/pinentry";
  };

  xdg = {
    # todo: move this into home-manager configuration
    configFile."gnupg/gpg.conf".source = old_dots + /gnupg/gpg.conf;
  };
}
