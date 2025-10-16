{ config, pkgs, ... }:
{
  imports = [ <nixpkgs/nixos/modules/virtualisation/amazon-image.nix> ];

  ec2.hvm = true;

  # Allow wheel users to sudo without password (useful for automation)
  security.sudo.wheelNeedsPassword = false;

  # Monitoring tools for the build process
  environment.systemPackages = with pkgs; [
    htop
    glances
  ];

  nix.settings = {
    system-features = [ "benchmark" "big-parallel" "kvm" "nixos-test"%{ if gccarch_feature != "" } "${gccarch_feature}"%{ endif } ];
    max-jobs = "auto";
    cores = 0;

    # Increase download buffer for large derivations
    download-buffer-size = 4194304000;

    # Binary cache configuration - fetch from Cheetah cache first (fast OVH-AWS transfer)
    substituters = [
      "https://nix-cache.apps.ondy.org"
      "https://cache.nixos.org"
    ];

    # Trusted public keys for binary caches
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-cache.apps.ondy.org:CoR5HjnPwbBVUlQtBo7yUGRcX3VSG0ai9lQNx9wAMWU=%"
    ];
  };
}
