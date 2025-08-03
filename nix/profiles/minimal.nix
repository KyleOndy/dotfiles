# Minimal profile - bare essentials only
# Suitable for containers, VMs, or resource-constrained environments

{ ... }:
{
  imports = [ ./common/base.nix ];

  # No additional features enabled
  hmFoundry.features = {
    isDevelopment = false;
    isDesktop = false;
    isServer = false;
    isGaming = false;
  };
}
