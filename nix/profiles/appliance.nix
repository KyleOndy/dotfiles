# Appliance profile - headless single-purpose machines that hold data.
#
# server.nix is the wrong shape for these. It imports common/development.nix,
# which does two things an appliance cannot accept:
#
#   1. turns on pi-coding-agent, whose sourceDir throws unless
#      DOTFILES_WORKTREE is set (hm_modules/dev/pi-coding-agent:74-83)
#   2. sets hmFoundry.dev.enable, which is the flag tools.nix gates on, and
#      tools.nix carries berkeley-mono and pragmata-pro. Both are git-crypt
#      encrypted, and the font derivation asserts on decrypted content, so
#      the build fails outright without the key.
#
# Either one stops the host evaluating its own configuration, which is
# precisely what a deploy-rs node with remoteBuild = true has to do. So this
# profile enables the hmFoundry.dev sub-flags it wants and never sets
# hmFoundry.dev.enable itself. Each sub-module gates on its own leaf option,
# so that works.

{ ... }:
{
  imports = [
    ./common/base.nix
    # No development.nix. Not weight, blockers. See above.
    # No desktop.nix. Headless.
    # No ssh-hosts.nix. Nothing here initiates ssh to the rest of the fleet.
  ];

  hmFoundry = {
    # development.nix is where these normally come from.
    shell = {
      zsh.enable = true;
      bash.enable = true;
      starship.enable = true;
    };

    # tmux earns its place here: seeding and resilvering are multi-hour jobs
    # run over ssh, and losing one to a dropped connection is the whole cost.
    terminal.tmux.enable = true;

    dev = {
      # `enable` stays unset on purpose. Setting it pulls in tools.nix and
      # the two git-crypt fonts with it.
      aws.enable = true; # awscli2, for the S3 archive tier
      sysadmin.enable = true; # htop, lsof, dnsutils, nmap, mosh
      monitoring.enable = true; # silence-host, for maintenance windows
    };
  };

  # No neovim module here. deployment_target.nix already puts neovim in
  # environment.systemPackages on every NixOS node, which is enough for
  # fixing a typo at 2am. Anything more involved happens from a real machine.
}
