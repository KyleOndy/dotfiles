{
  lib,
  pkgs,
  config,
  inputs,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.terminal.editors.neovim;
in
{
  options.hmFoundry.terminal.editors.neovim = {
    enable = mkEnableOption "neovim with nixCats";
  };

  config = mkIf cfg.enable {
    # Enable nixCats nvim package
    # Configuration is in flake.nix, homeModule auto-imported via sharedModules
    # The moduleNamespace in flake.nix is ["nvim"], so options are under nvim.*
    nvim = {
      enable = true;
      # Specify which packageDefinition to use (defined in flake.nix)
      packageNames = [ "nvim" ];
    };

    # Provision Lua configuration files
    xdg.configFile."nixCats-nvim/lua" = {
      source = ./lua;
      recursive = true;
    };

    # Ensure root init.lua is provisioned
    xdg.configFile."nixCats-nvim/lua/init.lua".source = ./lua/init.lua;

    # Provision spell files
    xdg.configFile."nixCats-nvim/spell/shared.en.utf-8.add".text = ''
      AWS
      Clojure
      darwin
      fixup
      initramfs
      inline
      inode
      inotify
      MUA
      Neovim
      NixOS
      nixpkgs
      nvme
      pixicore
      pkgs
      plugin
      plugins
      precommit
      ramroot
      rebase
      Reusability
      sd
      Terraform
      todo
      urls
      vim
      zsh
    '';
  };
}
