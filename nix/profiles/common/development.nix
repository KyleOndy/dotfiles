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
          enable = true;
          globalDepsEdn.enable = true;
        };
        python.enable = true;
        dotnet.enable = false;
        hashicorp.enable = false;
        git.enable = true;
        haskell.enable = false;
        nix.enable = true;
        go.enable = true;
      };
      shell = {
        zsh.enable = true;
        bash.enable = true;
      };
      terminal = {
        email.enable = true;
        tmux.enable = true;
        gpg.enable = true;
        pass.enable = true;
        editors = {
          neovim.enable = true;
        };
      };
    };

    # All packages are now handled by the dev modules based on feature flags
    # The modules automatically include packages when:
    # - hmFoundry.dev.enable = true (core packages)
    # - hmFoundry.features.isKubernetes = true (k8s tools)
    # - hmFoundry.features.isAWS = true (AWS tools)
    # - etc.
  };
}
