# SSH configuration for root user on trex
# This enables sops-nix and remote builders to work properly
{ ... }:
{
  # SSH client configuration for root user
  programs.ssh = {
    # This lands in /etc/ssh/ssh_config.d, which every user reads, so the
    # tiger block is scoped to root by Match rather than Host.
    extraConfig = ''
      Match localuser root originalhost tiger,tiger.dmz.1ella.com
        HostName tiger.dmz.1ella.com
        User svc.nixbuild
        Port 2332
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
