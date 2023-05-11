{ pkgs, ... }:
{
  networking = {
    useDHCP = false;
    interfaces.enp2s0.useDHCP = true;
    interfaces.enp3s0.useDHCP = true;
  };
  environment.systemPackages = [ pkgs.hello ];
  fileSystems."/" = {
    device = "/dev/bogus";
    fsType = "ext4";
  };
  boot = {
    loader.grub.devices = [ "/dev/bogus" ];
    postBootCommands = ''
      PATH=${pkgs.nix}/bin /nix/.nix-netboot-serve-db/register
    '';
  };
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };
  users.users.root = {
    password = "hunter2";
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDZq6q45h3OVj7Gs4afJKL7mSz/bG+KMG0wIOEH+wXmzDdJ0OX6DLeN7pua5RAB+YFbs7ljbc8AFu3lAzitQ2FNToJC1hnbLKU0PyoYNQpTukXqP1ptUQf5EsbTFmltBwwcR1Bb/nBjAIAgi+Z54hNFZiaTNFmSTmErZe35bikqS314Ej60xw2/5YSsTdqLOTKcPbOxj2kulznM0K/z/EDcTzGqc0Mcnf51NtzxlmB9NR4ppYLoi7x+rVWq04MbdAmZK70p5ndRobqYSWSKq+WDUAt2+CiTm6ItDowTLuo3zjHyYV1eCnB35DdakKVldIHrQyhmhbf5hJi6Ywx6XCzlFoNpkl/++RrJT2rf0XpGdlRoLQoKFvNRfnO4LI499SIfFb9Pwq7LhF1C1kTmshN/9S44d6VCCYXLE4uS8OPv7IXxUvFQZaIKCbomd2FzXxUwf4lg2gSlczysgDaVsMAUvlfDVgTFX8Xt1LFl3DqNtUiUpa9+Jnst/jCqqOBf3e8= kyle@alpha"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII06ucMODALjreR0beoVmxbAikW72cZBpfBXG/ZU9nbH kyle@alpha"
    ];
  };
}
