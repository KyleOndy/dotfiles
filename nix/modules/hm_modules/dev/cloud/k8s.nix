# Kubernetes development tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.kubernetes;
in
{
  options.hmFoundry.dev.kubernetes = {
    enable = mkEnableOption "Kubernetes development tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      k9s
      kubectl
      kubectl-node-shell
      kubectx
      kubernetes-helm
      kustomize
      kind
    ];
  };
}
