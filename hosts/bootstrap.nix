{ config, pkgs, ... }:
{
  # This file is intendend to be imported into a new host's config during
  # inital install. this config allows the deployment process to be run on this
  # host.
  # There is some manual work in keeping this file in sync with changes I make
  # in the deployment_taget module.

  users.users."svc.deploy" = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword =
      "$6$XTNiJhQm1$D3M90syVNZdTazCOZIAF8TLK/hD4oSi3Xdst62dCkWR44ia3rujnPx.yWT6BaU4tvu1im5nR20WcjWnhPMTIV/";
    shell = pkgs.bash_5;
    # todo: make a key for just deploys
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDZq6q45h3OVj7Gs4afJKL7mSz/bG+KMG0wIOEH+wXmzDdJ0OX6DLeN7pua5RAB+YFbs7ljbc8AFu3lAzitQ2FNToJC1hnbLKU0PyoYNQpTukXqP1ptUQf5EsbTFmltBwwcR1Bb/nBjAIAgi+Z54hNFZiaTNFmSTmErZe35bikqS314Ej60xw2/5YSsTdqLOTKcPbOxj2kulznM0K/z/EDcTzGqc0Mcnf51NtzxlmB9NR4ppYLoi7x+rVWq04MbdAmZK70p5ndRobqYSWSKq+WDUAt2+CiTm6ItDowTLuo3zjHyYV1eCnB35DdakKVldIHrQyhmhbf5hJi6Ywx6XCzlFoNpkl/++RrJT2rf0XpGdlRoLQoKFvNRfnO4LI499SIfFb9Pwq7LhF1C1kTmshN/9S44d6VCCYXLE4uS8OPv7IXxUvFQZaIKCbomd2FzXxUwf4lg2gSlczysgDaVsMAUvlfDVgTFX8Xt1LFl3DqNtUiUpa9+Jnst/jCqqOBf3e8= kyle@alpha"
    ];
  };
  services.openssh.enable = true;
  nix = {
    package = pkgs.nixStable;
    trustedUsers = [ "root" "@wheel" ]; # todo: security issue?
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };
  security.sudo.wheelNeedsPassword = false;
}
