{
  modulesPath,
  lib,
  pkgs,
  ...
}@args:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disk-config.nix
  ];

  boot.loader.grub = {
    # no need to set devices, disko will add all devices that have a EF02 partition to the list already
    # devices = [ ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  # Enable mdadm for RAID1 support
  boot.swraid.enable = true;
  boot.swraid.mdadmConf = ''
    MAILADDR root
  '';

  networking.hostName = "bear";

  services.openssh.enable = true;

  environment.systemPackages = map lib.lowPrio [
    pkgs.coreutils-full
    pkgs.curl
    pkgs.gitMinimal
    pkgs.neovim
  ];

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKtqba65kXXovFMhf0fR02pTlBJ8/w1bj24wqJuQmUZ+ kyle@dino"
  ];

  system.stateVersion = "24.05";
}
