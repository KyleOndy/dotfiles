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
    # Install-time-only throwaway. sops has no enrolled key for this host yet
    # (that's the whole point of bootstrap.nix), so hashedPasswordFile isn't
    # usable here. deployment_target.nix switches svc.deploy to a sops-backed
    # hashedPasswordFile once the host's age key is added to .sops.yaml and
    # the first real deploy runs. Regenerate this hash (mkpasswd -m sha-512)
    # if it's ever suspected of being reused anywhere.
    hashedPassword = "$6$Pnjbk9PVroeJvgkL$vJPI/4pL0Xei70YDdnGg5MckSfeAypn1Ctuc9WPvS3j62RZMv8zB6cWmlAyjRmg70s36QRXwENf50H9KmbqlN/";
    shell = pkgs.bashInteractive;
    # todo: make a key for just deploys
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDKPwXdnorhTtQOZ0iE3YJHtb8YYfhjnaav8ArQQuIOQR4tAxPyxMucKHuTsCH3soFFBTY1wg0KVt4x+6op4bfhr0Q40bqQprwy/5LFmui1FZhFhAxrbx4abK0Kh6NaKjvYmV1Lh9+gSKTK9edxWixX90ZI6YHhVEf5JSeUbVcKYKMD4gp5CR5EC2l8/bd/4nQ3n74Od4faa4DfE4qaleEQ4IcAONR0WGxtX1aP2Q4V+UfbS2gvBA0c/V0eIIXnscMcqBbzrYPMxQ7a8umpA65ByHgdFBnCeyvhKjxl2E1HoZcPzruBXs/NqmvnhG6iuFDPtG2G+Lj6xjEYffJcI2VnkYAyczD63P6zlsBIPbyvq7aS8jGR0CsNbfJExjXLmB3M4k2ANBidfai26zAN/Pn73MOA9ieShy1FUZCYf3nM5+EO+0Al6v48eJXNrcUNqKRUHEdyRi+Sd3Nj5shZ61lgCdSZk78XUjXpWcmhbFGaR+9aXn3kUV5rDjqpLzp4alU= kyle@dino"
    ];
  };
  services.openssh.enable = true;
  nix = {
    package = pkgs.nixStable;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
    settings = {
      # Narrowed from [ "root" "@wheel" ] to match deployment_target.nix:
      # only svc.deploy needs Nix trust here (deploy-rs); kyle uses sudo/root
      # for any privileged Nix operations instead.
      trusted-users = [
        "root"
        "svc.deploy"
      ];
    };
  };
  # Intentional, matches deployment_target.nix: deploy-rs needs unprompted
  # sudo since it activates dynamic, per-deploy store paths.
  security.sudo.wheelNeedsPassword = false;
}
