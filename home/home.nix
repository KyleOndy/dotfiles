{ pkgs, ... }:

# This is the entry point for home-manager. This file should mainly be to
# import other more specific files and be a catchall for _few_ settings that
# don't belong in another file.

{
  nixpkgs.config.allowUnfree = true;
  # import each nix file into home-manager
  imports = [
    ./email.nix
    ./env.nix
    ./firefox.nix
    ./fonts.nix
    ./git.nix
    ./gpg.nix
    ./gui.nix
    ./haskell.nix
    #./mbsync.nix
    #./msmtp.nix
    ./neomutt.nix
    ./neovim.nix
    #./notmuch.nix
    ./packages.nix
    ./python.nix
    ./rss.nix
    ./scripts.nix
    ./tarsnap.nix
    ./tmux.nix
    ./weechat.nix
    ./zsh.nix
  ];

  # import all the overlays that extend packages beyond their configurability
  # via nix or home-manager. Overlays are a nix file within the `overlay`
  # folder or a subfolder in `overlay` that contains a `default.nix`.
  nixpkgs.overlays = let path = ./overlays;
  in with builtins;
  map (n: import (path + ("/" + n))) (filter (n:
    match ".*\\.nix" n != null
    || pathExists (path + ("/" + n + "/default.nix")))
    (attrNames (readDir path)));

  # todo: can this be pulled down with a git submodule?
  # the NUR is needed for adding extensions to firefox.
  nixpkgs.config.packageOverrides = pkgs: {
    nur = import (builtins.fetchTarball
      "https://github.com/nix-community/NUR/archive/master.tar.gz") {
        inherit pkgs;
      };
  };

  # let home-manager manage itself
  programs = {
    home-manager = { enable = true; };
    lesspipe.enable = true;
  };

}
