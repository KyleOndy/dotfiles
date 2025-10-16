# Example home-manager configuration for macOS work environment
# This extends the base workstation profile with work-specific settings

{
  config,
  pkgs,
  lib,
  ...
}:
{
  # Import the base workstation profile to get all standard development tools
  imports = [ ../profiles/workstation.nix ];

  # Work-specific packages
  home.packages = with pkgs; [
    # Cloud tools
    awscli2
    google-cloud-sdk
    azure-cli

    # Kubernetes tools
    kubectl
    kubectx
    k9s
    helm

    # Development tools
    postman
    insomnia

    # Communication tools (if not handled by homebrew)
    # teams
    # slack-term

    # Company-specific tools would go here
    # internal-dev-tool
    # proprietary-analyzer
  ];

  # Git configuration for work
  programs.git = {
    userEmail = lib.mkForce "your.name@company.com";
    userName = lib.mkForce "Your Name";

    # Work-specific git settings
    extraConfig = {
      # Use work GitHub/GitLab for work repos
      url."git@work-github.com:" = {
        insteadOf = "https://work-github.com/";
      };

      # Signing commits with work GPG key
      user.signingkey = "WORK_GPG_KEY_ID";
      commit.gpgsign = true;

      # Company-specific git configurations
      core = {
        # Use company's diff tool
        # difftool = "company-diff";
      };

      # Different pull strategy for work
      pull.rebase = true;
    };

    # Work-specific git aliases
    aliases = {
      # Company workflow aliases
      feature = "checkout -b feature/";
      hotfix = "checkout -b hotfix/";
      pr = "!gh pr create --assignee @me";
    };
  };

  # SSH configuration for work servers
  programs.ssh = {
    matchBlocks = {
      "work-bastion" = {
        hostname = "bastion.company.com";
        user = "your-username";
        forwardAgent = true;
      };

      "work-dev-*" = {
        proxyJump = "work-bastion";
        user = "your-username";
        forwardAgent = true;
      };

      "work-prod-*" = {
        proxyJump = "work-bastion";
        user = "your-username";
        forwardAgent = false; # No agent forwarding to prod
      };
    };
  };

  # Shell configuration
  programs.zsh = {
    shellAliases = {
      # Kubernetes aliases for work clusters
      kdev = "kubectl --context=dev-cluster";
      kstage = "kubectl --context=staging-cluster";
      kprod = "kubectl --context=prod-cluster";

      # AWS profile switching
      aws-dev = "export AWS_PROFILE=company-dev";
      aws-prod = "export AWS_PROFILE=company-prod";

      # Company-specific shortcuts
      vpn = "tailscale up --accept-routes";
      vpn-down = "tailscale down";

      # Quick access to work directories
      work = "cd ~/work";
      repos = "cd ~/work/repos";
    };

    # Work-specific environment variables
    sessionVariables = {
      WORK_ENV = "true";
      DEFAULT_AWS_PROFILE = "company-dev";
      DOCKER_REGISTRY = "docker.company.com";
      NPM_REGISTRY = "https://npm.company.com";
    };

    # Additional work-specific zsh configuration
    initExtra = ''
      # Auto-switch kubectl context based on directory
      function chpwd_kubectl() {
        if [[ -f .kubectl-context ]]; then
          local context=$(cat .kubectl-context)
          kubectl config use-context "$context"
        fi
      }
      add-zsh-hook chpwd chpwd_kubectl

      # Company-specific shell functions
      function aws-login() {
        aws sso login --profile "$1"
      }

      function k8s-debug() {
        kubectl run -it debug-''${USER} --image=alpine --restart=Never --rm -- sh
      }
    '';
  };

  # VS Code settings for work
  programs.vscode = {
    userSettings = {
      # Work-specific settings
      "git.defaultBranchName" = "develop"; # If company uses gitflow
      "remote.SSH.defaultHost" = "work-dev-server";

      # Company code style
      "editor.rulers" = [ 100 ]; # Company style guide line length

      # Work-specific extensions settings
      "github.enterprise.uri" = "https://github.company.com";
    };
  };

  # Direnv for project-specific environments
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;

    # Whitelist work directories
    config.whitelist = {
      prefix = [ "~/work" ];
    };
  };

  # Work-specific tmux configuration
  programs.tmux = {
    extraConfig = ''
      # Show kubernetes context in status bar
      set -g status-right '#[fg=blue]#(kubectl config current-context) #[default]| %H:%M '
    '';
  };
}
