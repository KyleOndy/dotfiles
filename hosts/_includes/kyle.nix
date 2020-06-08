# this is the config for my own user.
#
{ config, pkgs, ... }:

{
  users.users.kyle = {
    isNormalUser = true;
    extraGroups = [ "audio" "docker" "wheel" ]; # Enable ‘sudo’ for the user.
    # despite being able to change the password, every time NixOS is rebuild,
    # the password gets reset.
    initialHashedPassword =
      "$6$hYiIwvTIv$2Z3lBfOQYi4IymaU2CLW2UwJcLfAvtEt1zAw5LJ/qtWQ/rnDEVLmwtaTJW4iUfRAH9QjzV10rHm06wgqvSXWt1";
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      # juice ssh for android
      "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBCY48p/4M/8CcfQgq/4J/bYRflVQ2MFovineycMxsEorlW50oOm1SJ8nn2qAAE75bxgbqbmFPBNdV1JUx/9DAnTITqw13lKdb09M2c59NQN6LjaL1SUbboiSxiwv6hHtAg== JuiceSSH"
    ];
  };
  # todo: do not hardcode pahts?
  # setting the path here avoid the need to set HOME_MANAGER_PATH and we can
  # build everything with `./make.sh`. This uses `nix build` under the hood and
  # give much cleaner output to stdout than `nixos-rebuild` or `home-manager
  # build`. Vanity, but its true.
  home-manager.users.kyle = args: import ../../home/home.nix (args // { inherit pkgs; });

}
