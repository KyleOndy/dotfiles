# for laptops, power management.

{ config, pkgs, ... }: {
  powerManagement = {
    enable = true;
    #cpuFreqGovernor = null;
    # Enable PowerTop auto-tuning
    powertop.enable = true;
  };
  services.tlp = {
    enable = true;
    settings = {
      PCIE_ASPM_ON_BAT = "powersupersave";
    };
  };
}
