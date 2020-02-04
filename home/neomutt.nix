{ pkgs, ... }:

let
  old_dots = import ./_dotfiles-dir.nix;

in
{
  home.packages = with pkgs; [
    neomutt # MUA
    urlview # easily open urls within emails
  ];
  xdg = {
    configFile."neomutt/neomuttrc".source = old_dots + /neomutt/neomuttrc;
    configFile."neomutt/mutt-colors-solarized-dark-256.muttrc".source = old_dots
    + /neomutt/mutt-colors-solarized-dark-256.muttrc;
    configFile."neomutt/bindings.muttrc".source = old_dots
    + /neomutt/bindings.muttrc;
    configFile."neomutt/macros.muttrc".source = old_dots
    + /neomutt/macros.muttrc;
    configFile."neomutt/gpg.muttrc".source = old_dots + /neomutt/gpg.muttrc;
    configFile."neomutt/hooks.muttrc".source = old_dots + /neomutt/hooks.muttrc;
  };
}
