{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.dev.hashicorp;
in
{
  options.foundry.dev.hashicorp = {
    enable = mkEnableOption "hashitools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      consul
      nomad
      packer
      terraform_0_15
      vagrant
      vault

      # hashi-related
      terraform-docs # auto documentation generation
      tflint # better terraform linter
      tfsec #  static analysis of terraform

      # for neovim
      terraform-ls
    ];
    programs.neovim = {
      plugins = with pkgs.vimPlugins; [{
        plugin = vim-terraform;
        config = ''
          let g:terraform_align=1
          let g:terraform_fmt_on_save=1
        '';
      }];
    };
  };
}
