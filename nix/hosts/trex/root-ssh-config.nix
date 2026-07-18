# SSH configuration for root user on trex
# This enables sops-nix and remote builders to work properly
{ ... }:
{
  # SSH client configuration for root user
  programs.ssh = {
    extraConfig = ''
      Host tiger tiger.dmz.1ella.com
        HostName tiger.dmz.1ella.com
        User svc.deploy
        Port 2332
        IdentityFile /var/root/.ssh/id_ed25519
        StrictHostKeyChecking accept-new
        ConnectTimeout 3

      Host trex trex.lan.1ella.com
        HostName trex.lan.1ella.com
        User svc.deploy
        IdentityFile /var/root/.ssh/id_ed25519
        StrictHostKeyChecking accept-new
        ConnectTimeout 3

      # Default settings for all hosts
      Host *
        IdentitiesOnly yes
        AddKeysToAgent yes
    '';
  };
}
