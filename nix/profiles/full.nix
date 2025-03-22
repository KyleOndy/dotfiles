{ pkgs, ... }:
{

  # This user profile is a superset of a the ssh profile. Only declare what
  # this profile has in addation to ssh profile or happens to be different.
  imports = [ ./ssh.nix ];

  hmFoundry = {
    desktop = {
      apps = {
        discord.enable = true;
        slack.enable = true;
      };
      browsers = {
        firefox.enable = true;
      };
      gaming.steam.enable = true;
      media = {
        documents.enable = true;
        makemkv.enable = true;
      };
      term = {
        wezterm.enable = true;
        foot.enable = true;
      };
      wm.i3.enable = false;
    };
  };
  home.packages = with pkgs; [
    deploy-rs # nixos deployment
    golden-cheetah # cycling analytics
    helios # hand rolled photo management
    remmina # remote desktop client
  ];
}
