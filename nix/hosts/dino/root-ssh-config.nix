# SSH configuration for root user on dino
# This enables deploy-rs and remote builders to work properly
{ ... }:
{
  # SSH client configuration for root user
  programs.ssh = {
    extraConfig = ''
      Host elk
        HostName 37.27.70.102
        User svc.deploy
        IdentityFile /root/.ssh/id_ed25519
        StrictHostKeyChecking accept-new
        ConnectTimeout 3

      Host dino dino.lan.1ella.com
        HostName dino.lan.1ella.com
        User svc.deploy
        IdentityFile /root/.ssh/id_ed25519
        StrictHostKeyChecking accept-new
        ConnectTimeout 3

      # Default settings for all hosts
      Host *
        IdentitiesOnly yes
        AddKeysToAgent yes
    '';
  };
}
