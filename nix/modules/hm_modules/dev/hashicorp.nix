{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.dev.hashicorp;
in
{
  options.hmFoundry.dev.hashicorp = {
    enable = mkEnableOption "hashitools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      #consul # borken on osx?
      nomad
      #packer # packer broke on osx
      terraform_1
      #vagrant # broke
      vault

      # hashi-related
      terraform-docs # auto documentation generation
      tflint # better terraform linter
      tfsec #  static analysis of terraform

      # for neovim
      terraform-ls

      # helpers
      terragrunt
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
