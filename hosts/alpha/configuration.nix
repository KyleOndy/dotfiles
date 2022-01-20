{ pkgs, ... }:

{
  nixpkgs = {
    config = {
      allowUnfree = true;
    };
  };

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.luks.devices = {
    root = {
      name = "root";
      device = "/dev/sda2";
      preLVM = true;
    };
  };
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];


  networking = {
    hostName = "alpha";
    #
    # The global useDHCP flag is deprecated, therefore explicitly set to false here.
    # Per-interface useDHCP will be mandatory in the future, so this generated config
    # replicates the default behaviour.
    useDHCP = false;
    interfaces.enp0s31f6.useDHCP = true;
    interfaces.wlp4s0.useDHCP = true;
    firewall = {
      allowedTCPPorts = [
        80 # HTTP
        8080 # whatever I feel like
        64172 # pixiecore
      ];
      allowedUDPPorts = [
        67 # dhcp: pixiecore
        69 # dhcp: pixcore
      ];
    };
    wireless.interfaces = [ "wlp4s0" ];
  };

  hardware = {
    enableAllFirmware = true;
    cpu.intel.updateMicrocode = true;
  };

  # no adhoc user managment
  users.mutableUsers = false;

  system.stateVersion = "19.09"; # Did you read the comment?

  # steam
  hardware.opengl.driSupport32Bit = true;
  hardware.opengl.extraPackages32 = with pkgs.pkgsi686Linux; [ libva ];
  hardware.pulseaudio.support32Bit = true;

}
