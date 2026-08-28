# NixOS guest for forge's docker host. nixpkgs' `qemu-efi` image variant turns
# this into the qcow2 that nix/pkgs/forge/vm.nix names as its image.
#
# Replaces the Ubuntu cloud image this booted before, whose docker came from an
# `apt-get install docker.io` on first boot: a version no flake input pinned,
# which unattended-upgrades could then change under a running cluster. Here it is
# whatever nixpkgs locks, and the guest has no package manager to move it.
#
# The boundary itself is not here. It is `mounts` and `portForwards` in vm.nix,
# enforced by lima's hostagent on the host side.
{ lib, pkgs, ... }:
{
  # From the nixos-lima flake. lima installs its guest agent by copying a binary
  # into the guest and writing a unit for it, which a read-only /nix/store
  # cannot accept, and lima's documented Linux guest requirements name a package
  # manager NixOS does not have. This module runs lima-init and lima-guestagent
  # as systemd services instead.
  services.lima.enable = true;

  # lima reaches the guest over ssh, and the port-forward denial in vm.nix is
  # the hostagent acting on events lima-guestagent sends it, so without this the
  # instance never becomes ready.
  services.openssh.enable = true;

  # lima-init creates the instance user with useradd at boot, taking the name
  # from the host user, so nothing declarative here can name it.
  users.mutableUsers = true;
  security.sudo.wheelNeedsPassword = false;

  virtualisation.docker.enable = true;

  # nixpkgs marks the default `docker` (28.5.2) insecure, and this is the same
  # major forge's own runtimeInputs pin, so the CLI on the host and the daemon in
  # the guest stay in step.
  virtualisation.docker.package = pkgs.docker_29;

  # Consequence of that imperative user: it lands in `wheel` and `users`, and no
  # declarative `users.groups.docker.members` can name it, so the socket lima
  # forwards has to be reachable through a group it is already in. Everything
  # that can reach this socket is root-equivalent in the guest regardless, which
  # is the premise vm.nix's header sets out.
  systemd.sockets.docker.socketConfig.SocketGroup = lib.mkForce "users";

  # Each kind node runs a systemd watching that node's filesystem, so the
  # default 128 instances is gone after a few clusters.
  boot.kernel.sysctl = {
    "fs.inotify.max_user_instances" = 1024;
    "fs.inotify.max_user_watches" = 524288;
  };

  system.stateVersion = "25.11";
}
