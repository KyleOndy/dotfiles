# SSH configuration for root user on elk
# Enables rsync/SSH from elk to wolf for media sync
{ ... }:
{
  programs.ssh = {
    extraConfig = ''
      Host wolf
        HostName ns568215.ip-51-79-99.net
        User svc.deploy
        IdentityFile /root/.ssh/id_ed25519
        StrictHostKeyChecking accept-new
        ConnectTimeout 10

      Host *
        IdentitiesOnly yes
        AddKeysToAgent yes
    '';
  };
}
