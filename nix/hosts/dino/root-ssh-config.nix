# SSH configuration for root user on dino
# This enables deploy-rs and remote builders to work properly
{ ... }:
{
  # SSH client configuration for root user
  programs.ssh = {
    extraConfig = ''
      Host tiger tiger.dmz.1ella.com
        HostName tiger.dmz.1ella.com
        User svc.deploy
        Port 2332
        IdentityFile /root/.ssh/id_ed25519
        StrictHostKeyChecking accept-new
        ConnectTimeout 10

      Host cheetah
        HostName ns100099.ip-147-135-1.us
        User svc.deploy
        IdentityFile /root/.ssh/id_ed25519
        StrictHostKeyChecking accept-new
        ConnectTimeout 10

      Host dino dino.lan.1ella.com
        HostName dino.lan.1ella.com
        User svc.deploy
        IdentityFile /root/.ssh/id_ed25519
        StrictHostKeyChecking accept-new
        ConnectTimeout 10

      Host alpha alpha.lan.1ella.com
        HostName alpha.lan.1ella.com
        User svc.deploy
        IdentityFile /root/.ssh/id_ed25519
        StrictHostKeyChecking accept-new
        ConnectTimeout 10

      # Default settings for all hosts
      Host *
        IdentitiesOnly yes
        AddKeysToAgent yes
    '';
  };
}
