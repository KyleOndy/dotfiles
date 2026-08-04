# Install and rescue media for pika. The stock minimal ISO installs this board
# fine, but boots with empty passwords and no authorized key, so it wants a
# keyboard and a monitor before it answers ssh. This one comes up headless, and
# the base profile's smartmontools, nvme-cli, gptfdisk and ZFS make it worth
# keeping in the drawer for the drive questions still open in
# docs/backup-strategy.md.

{
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  # mkForce because iso-image.nix sets baseName without mkDefault.
  image.baseName = lib.mkForce "pika-installer";

  # The install is headless, so `ssh root@pika-installer.local` from trex has
  # to work without knowing the DHCP lease. macOS resolves .local natively.
  networking.hostName = "pika-installer";
  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  services.openssh.settings.PermitRootLogin = "prohibit-password";
  users.users.root.openssh.authorizedKeys.keys = import ../../lib/kyle-authorized-keys.nix;

  # Matches pika, so a pool created here carries the id the installed system
  # expects rather than needing `zpool import -f`.
  networking.hostId = "ae260477";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = with pkgs; [
    git
    rsync
  ];
}
