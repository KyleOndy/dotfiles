{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.users.kyle;
in
{
  options.systemFoundry.users.kyle = {
    enable = mkEnableOption ''
      My basic daily driver user
    '';
  };

  config = mkIf cfg.enable {
    programs = {
      zsh.enable = true;
    };
    users.users.kyle = {
      isNormalUser = true;
      group = "kyle";
      extraGroups = [
        "audio"
        "dialout" # microcontoller dev
        "docker"
        "input" # input device access for trackball remapping
        "networkmanager"
        "render" # gpu access
        "video" # camera/capture device access
        "wheel" # Enable 'sudo' for the user.
      ];
      # despite being able to change the password, every time NixOS is rebuild,
      # the password gets reset.
      initialHashedPassword = "$6$hYiIwvTIv$2Z3lBfOQYi4IymaU2CLW2UwJcLfAvtEt1zAw5LJ/qtWQ/rnDEVLmwtaTJW4iUfRAH9QjzV10rHm06wgqvSXWt1";
      shell = pkgs.zsh;
      openssh.authorizedKeys.keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDKPwXdnorhTtQOZ0iE3YJHtb8YYfhjnaav8ArQQuIOQR4tAxPyxMucKHuTsCH3soFFBTY1wg0KVt4x+6op4bfhr0Q40bqQprwy/5LFmui1FZhFhAxrbx4abK0Kh6NaKjvYmV1Lh9+gSKTK9edxWixX90ZI6YHhVEf5JSeUbVcKYKMD4gp5CR5EC2l8/bd/4nQ3n74Od4faa4DfE4qaleEQ4IcAONR0WGxtX1aP2Q4V+UfbS2gvBA0c/V0eIIXnscMcqBbzrYPMxQ7a8umpA65ByHgdFBnCeyvhKjxl2E1HoZcPzruBXs/NqmvnhG6iuFDPtG2G+Lj6xjEYffJcI2VnkYAyczD63P6zlsBIPbyvq7aS8jGR0CsNbfJExjXLmB3M4k2ANBidfai26zAN/Pn73MOA9ieShy1FUZCYf3nM5+EO+0Al6v48eJXNrcUNqKRUHEdyRi+Sd3Nj5shZ61lgCdSZk78XUjXpWcmhbFGaR+9aXn3kUV5rDjqpLzp4alU= kyle@dino"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKtqba65kXXovFMhf0fR02pTlBJ8/w1bj24wqJuQmUZ+ kyle@dino"
      ];
    };
    users.groups.kyle = { };
  };
}
