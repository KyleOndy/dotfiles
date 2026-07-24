{ config, pkgs, ... }:
{
  # configure proprietary drivers
  nixpkgs.config.allowUnfree = true;
  boot.initrd.kernelModules = [ "wl" ];
  boot.kernelModules = [
    "kvm-intel"
    "wl"
  ];
  boot.extraModulePackages = [ config.boot.kernelPackages.broadcom_sta ];

  # programs that should be available in the installer
  environment.systemPackages = with pkgs; [
    bat
    git
    neovim
    rsync
  ];

  # Enable SSH in the boot process.
  systemd.services.sshd.wantedBy = pkgs.lib.mkForce [ "multi-user.target" ];
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJl9x835n7Sw4zbxo0bVGNsp0i3cITyYg6WOMj2DBkf kyle@trex.lan.1ella.com"
  ];
}
