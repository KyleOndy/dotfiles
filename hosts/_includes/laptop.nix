# for laptops, power management.

{ config, pkgs, ... }: {
  powerManagement = {
    cpuFreqGovernor = null;
    # Enable PowerTop auto-tuning
    powertop.enable = true;
  };
}
