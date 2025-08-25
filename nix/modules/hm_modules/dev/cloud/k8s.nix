# Kubernetes development tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.features;
  devCfg = config.hmFoundry.dev;
in
{
  config = mkIf (devCfg.enable && cfg.isKubernetes) {
    home.packages = with pkgs; [
      k9s
      kubectl
      kubectl-node-shell
      kubectx
      kubernetes-helm
      kind
    ];
  };
}
