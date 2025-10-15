# Shared environment variables used across profiles

{
  pkgs,
  config,
  dotfiles-root,
  ...
}:
{
  home.sessionVariables = {
    DOTFILES = "${config.home.homeDirectory}/src/dotfiles/main";
    DOTFILES_STORE = dotfiles-root;
    FOUNDRY_DATA = "${config.home.homeDirectory}/src/foundry";
    EDITOR = "nvim";
    VISUAL = "nvim";
    # this allows the rest of the nix tooling to use the same nixpkgs that I
    # have set in the flake.
    NIX_PATH = "nixpkgs=${pkgs.path}";
    MANPAGER = "nvim +Man! -- ";

    # TODO: even if we aren't using GPG, we need this set before trying to
    #       use the GPG module. Race condition I need to fix later.
    GNUPGHOME = "${config.home.homeDirectory}/.gnupg";
  };
}
