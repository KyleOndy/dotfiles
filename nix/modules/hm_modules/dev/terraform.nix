{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.terraform;
in
{
  options.hmFoundry.dev.terraform = {
    enable = mkEnableOption "terraform development tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      terraform_1

      # hashi-related
      terraform-docs # auto documentation generation
      tflint # better terraform linter
      tfsec # static analysis of terraform

      # for neovim
      terraform-ls

      # helpers
      terragrunt
    ];
  };
}
