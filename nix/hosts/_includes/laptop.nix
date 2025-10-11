# for laptops, power management.

{ config, pkgs, ... }:
{
  powerManagement = {
    enable = true;
    #cpuFreqGovernor = null;
    # Enable PowerTop auto-tuning
    powertop.enable = true;
  };

  # Intel thermal management daemon
  # Proactively prevents overheating and works well with TLP
  services.thermald.enable = true;

  services.tlp = {
    enable = true;
    settings = {
      # CPU Settings
      CPU_BOOST_ON_BAT = 0;
      CPU_BOOST_ON_AC = 1;
      CPU_SCALING_GOVERNOR_ON_AC = "powersave";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";

      # Intel P-state performance settings (12th gen Alder Lake)
      CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
      CPU_MIN_PERF_ON_AC = 0;
      CPU_MAX_PERF_ON_AC = 100;
      CPU_MIN_PERF_ON_BAT = 0;
      CPU_MAX_PERF_ON_BAT = 30; # Cap CPU at 30% on battery for better battery life

      # PCIe ASPM (Active State Power Management)
      PCIE_ASPM_ON_AC = "default";
      PCIE_ASPM_ON_BAT = "powersupersave"; # Enables L1.2 low-power states

      # Runtime Power Management
      RUNTIME_PM_ON_AC = "on";
      RUNTIME_PM_ON_BAT = "auto";

      # NVMe power management
      AHCI_RUNTIME_PM_ON_AC = "on";
      AHCI_RUNTIME_PM_ON_BAT = "auto";
      AHCI_RUNTIME_PM_TIMEOUT = 15;

      # WiFi power saving
      WIFI_PWR_ON_AC = "off";
      WIFI_PWR_ON_BAT = "on";

      # USB autosuspend
      USB_AUTOSUSPEND = 1;
      USB_EXCLUDE_BTUSB = 0;
      USB_EXCLUDE_PHONE = 0;
      USB_EXCLUDE_PRINTER = 1;
      USB_EXCLUDE_WWAN = 0;

      # Battery charge thresholds (preserve battery health)
      START_CHARGE_THRESH_BAT0 = 90;
      STOP_CHARGE_THRESH_BAT0 = 97;
    };
  };
}
