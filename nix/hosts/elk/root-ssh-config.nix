# SSH configuration for root user on elk
{ ... }:
{
  programs.ssh = {
    extraConfig = ''
      Host *
        IdentitiesOnly yes
        AddKeysToAgent yes
    '';
  };
}
