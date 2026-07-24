# Development tools and configuration
# Used by profiles that need development capabilities
# Packages are now managed by feature-flag-aware modules in hmFoundry.dev

{
  pkgs,
  lib,
  config,
  ...
}:
with lib;
{
  # Import environment variables commonly needed for development
  imports = [ ./env.nix ];

  config = {
    # Development language and tool configurations
    hmFoundry = {
      # foundry is the namespace I've given to my internal modules
      dev = {
        enable = true;
        clojure = {
          enable = lib.mkDefault true;
          globalDepsEdn.enable = lib.mkDefault true;
        };
        python.enable = lib.mkDefault true;
        dotnet.enable = lib.mkDefault false;
        terraform.enable = lib.mkDefault false;
        git.enable = lib.mkDefault true;
        haskell.enable = lib.mkDefault false;
        nix.enable = lib.mkDefault true;
        go.enable = lib.mkDefault true;
        rust.enable = lib.mkDefault true;
        pi-coding-agent = {
          enable = lib.mkDefault true;
          # pi 0.80.5's startup tmux keyboard probe (checkTmuxKeyboardSetup)
          # calls spawn("tmux") when $TMUX is set; the strict srt sandbox
          # denies that exec and pi does not catch the synchronous spawn
          # EPERM, so it crashes on launch inside tmux. Forcing TMUX empty
          # makes pi skip the probe. TMUX is read in exactly one place in
          # pi (the probe), and empty is harmless outside tmux.
          sandbox.envVars.TMUX = "";
        };
      };
      shell = {
        zsh.enable = true;
        bash.enable = true;
        starship.enable = true;
      };
      terminal = {
        # notmuch/neomutt/mbsync only run on trex; enabled there explicitly.
        email.enable = lib.mkDefault false;
        tmux.enable = true;
        gpg.enable = true;
        pass.enable = true;
        editors = {
          neovim.enable = true;
        };
      };
    };

    # All packages are now handled by the dev modules
    # Enable features by setting the corresponding dev module:
    # - hmFoundry.dev.kubernetes.enable = true
    # - hmFoundry.dev.aws.enable = true
    # - hmFoundry.dev.terraform.enable = true
    # - etc.
  };
}
