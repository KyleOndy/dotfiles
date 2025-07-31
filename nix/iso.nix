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
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDKPwXdnorhTtQOZ0iE3YJHtb8YYfhjnaav8ArQQuIOQR4tAxPyxMucKHuTsCH3soFFBTY1wg0KVt4x+6op4bfhr0Q40bqQprwy/5LFmui1FZhFhAxrbx4abK0Kh6NaKjvYmV1Lh9+gSKTK9edxWixX90ZI6YHhVEf5JSeUbVcKYKMD4gp5CR5EC2l8/bd/4nQ3n74Od4faa4DfE4qaleEQ4IcAONR0WGxtX1aP2Q4V+UfbS2gvBA0c/V0eIIXnscMcqBbzrYPMxQ7a8umpA65ByHgdFBnCeyvhKjxl2E1HoZcPzruBXs/NqmvnhG6iuFDPtG2G+Lj6xjEYffJcI2VnkYAyczD63P6zlsBIPbyvq7aS8jGR0CsNbfJExjXLmB3M4k2ANBidfai26zAN/Pn73MOA9ieShy1FUZCYf3nM5+EO+0Al6v48eJXNrcUNqKRUHEdyRi+Sd3Nj5shZ61lgCdSZk78XUjXpWcmhbFGaR+9aXn3kUV5rDjqpLzp4alU= kyle@dino"
  ];
}
