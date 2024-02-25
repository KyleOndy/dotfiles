{ pkgs, ... }:
{

  # This user profile is a superset of a the ssh profile. Only declare what
  # this profile has in addation to ssh profile or happens to be different.
  imports = [ ./ssh.nix ];

  hmFoundry = {
    desktop = {
      apps = {
        discord.enable = true;
      };
      browsers = {
        firefox.enable = true;
      };
      fonts.hack.enable = true;
      gaming.steam.enable = true;
      media = {
        documents.enable = true;
        makemkv.enable = true;
      };
      term.st.enable = true;
      wm.i3.enable = false;
    };
  };
}
