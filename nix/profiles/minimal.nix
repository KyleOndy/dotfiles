# Minimal profile - bare essentials only
# Suitable for containers, VMs, or resource-constrained environments

{ ... }:
{
  imports = [ ./common/base.nix ];

  # No additional features enabled - all dev modules default to disabled
}
