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
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII06ucMODALjreR0beoVmxbAikW72cZBpfBXG/ZU9nbH kyle@alpha"
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
