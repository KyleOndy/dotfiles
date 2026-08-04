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

    authorizedKeys = mkOption {
      type = types.listOf types.str;
      description = ''
        Kyle's personal SSH public keys, trusted for both the kyle and
        svc.deploy accounts across the NixOS fleet.
      '';
      default = import ../../../lib/kyle-authorized-keys.nix;
    };
  };

  config = mkIf cfg.enable {
    programs = {
      zsh.enable = true;
    };
    # neededForUsers: /etc/passwd is built before ordinary sops secrets are
    # decrypted, so this one is routed to /run/secrets-for-users earlier in
    # activation. sops-nix requires it to stay root-owned (no owner/group/mode).
    sops.secrets.kyle_password_hash.neededForUsers = true;
    users.users.kyle = {
      isNormalUser = true;
      group = "kyle";
      extraGroups = [
        "audio"
        "dialout" # microcontoller dev
        "input" # input device access for trackball remapping
        "networkmanager"
        "render" # gpu access
        "video" # camera/capture device access
        "wheel" # Enable 'sudo' for the user.
      ];
      # was initialHashedPassword (committed, reset every rebuild anyway
      # under mutableUsers = false). Now sops-backed and enforced every
      # activation instead of just on first boot.
      hashedPasswordFile = config.sops.secrets.kyle_password_hash.path;
      shell = pkgs.zsh;
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };
    users.groups.kyle = { };
  };
}
