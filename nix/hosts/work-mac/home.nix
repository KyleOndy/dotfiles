# Base home-manager configuration for work macOS environments
# The desktop profile is imported via mkDarwinSystem
# This file provides macOS-specific overrides and allows work-specific extensions via work-home.nix
{
  lib,
  pkgs,
  config,
  inputs,
  ...
}:
{
  imports = [ ];

  # Enable Karabiner for trackball button remapping
  hmFoundry.desktop.input.karabiner.enable = true;
  hmFoundry.desktop.input.karabiner.pushToTalk.enable = true;

  # Enable work context for shell completions (Linear tickets, etc.)
  home.sessionVariables = {
    DOTS_CONTEXT = "work";
    DOTFILES = lib.mkForce "/Users/kondy/src/kyleondy/dotfiles/main";
    WORK = "/Users/kondy/work";
    SRC_WORK = "${config.home.homeDirectory}/src/modularml";
    PDM_USE_VENV = "1"; # Configure PDM to use venv instead of __pypackages__
    CC = "/usr/bin/cc"; # Use system clang for C compilation (macOS SDK compatibility)
  };

  programs.zsh.shellAliases.src = lib.mkForce "cd ${config.home.homeDirectory}/src/modularml";

  # `pic CLIN-1008`, or `pic` from a worktree under a ticket directory, also
  # grants write on that ticket's notes dir. The coordinator's $PWD has to be
  # the repo the broker cuts worktrees from, so the notes dir never gets the
  # wrapper's implicit $PWD write grant.
  programs.zsh.initContent = ''
    pic() {
      # No --allow-forge: agents get their own instance from spawn_agent.
      local -a grants=(--allow-read ~/work --allow-linear --allow-kagi)
      local ticket
      if [[ $1 =~ '^[A-Z]+-[0-9]+$' ]]; then
        ticket=$1
        shift
      # {repo}/DEV-123/<name>, the layout git wt-feature-branch's work mode makes
      elif [[ $PWD:h:t =~ '^[A-Z]+-[0-9]+$' ]]; then
        ticket=$PWD:h:t
      fi
      if [[ -n $ticket ]]; then
        mkdir -p ~/work/tickets/$ticket
        grants+=(--allow-write ~/work/tickets/$ticket)
      fi
      pi --coordinator $grants "$@"
    }
  '';

  # Create modularml source directory
  home.activation.createModularmlDir = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
    mkdir -p $HOME/src/modularml
  '';

  # Add Homebrew to PATH for all managed shells (including Claude Code)
  home.sessionPath = [ "/opt/homebrew/bin" ];

  # Enable development modules
  hmFoundry.dev = {
    java.enable = true;

    # work-config owns this host's models and provider keys; the Kagi token is
    # not one of them, so it is resolved here from the same Keychain the
    # wrapper already reads mcloud's from. The entry has to exist on this
    # machine too: the wrapper hard-fails a resolver rather than starting
    # without the value.
    pi-coding-agent.sandbox.envFromCommands.KAGI_API_KEY = "security find-generic-password -s pi -a kagi -w";
    # critic.md pins zai/glm-5.3-flash, which bills the personal Z.ai plan.
    pi-coding-agent.sandbox.envVars.PI_AGENT_MODEL_CRITIC = "mcloud/moonshotai/kimi-k2.7-code";
    # The one host with forge, which every agent's VM comes from.
    pi-coding-agent.coordinator.enable = true;

    claude-code = {
      enable = true;
      skills = [
        {
          name = "golang-pro";
          source = "${inputs.claude-skills-jeffallan}/skills/golang-pro";
        }
        {
          name = "k8s-general";
          source = pkgs.runCommand "k8s-general-skill.md" { } ''
            sed 's/^name: kubernetes-specialist/name: k8s-general/' \
              ${inputs.claude-skills-voltagent}/categories/03-infrastructure/kubernetes-specialist.md > $out
          '';
          isFile = true;
        }
        {
          name = "k8s-operator";
          source = pkgs.runCommand "k8s-operator-skill.md" { } ''
            sed 's/^name: kubernetes-specialist/name: k8s-operator/' \
              ${inputs.claude-skills-rohitg00}/agents/infrastructure/kubernetes-specialist.md > $out
          '';
          isFile = true;
        }
      ];
    };
    kubernetes.enable = true; # kubectl, kubectx, k9s, helm, kustomize, kind
    nixTools.enable = true; # nixfmt, nixpkgs-review, nix-index
    sysadmin.enable = true; # htop, lsof, nmap, mosh, dnsutils
    go.installGo = false; # Use Homebrew Go for CGO compatibility on macOS

    # Enable Colima background service
    docker.service = {
      enable = true;
      cpu = 12;
      memory = 40;
      disk = 100;
      vmType = "vz";
      # Each kind node runs a systemd watching that node's filesystem, so the
      # default of 128 is gone after a couple of clusters. forge's own clusters
      # are not among them: they live in the VM nix/pkgs/forge/vm.nix declares,
      # which carries this limit in nix/pkgs/forge/guest.nix.
      sysctls = [ "fs.inotify.max_user_instances=1024" ];

      # Nothing from this mac is visible inside the VM, so a container started
      # through this daemon is not a route to ~/.ssh, ~/.aws or
      # ~/.config/sops. Anything reaching a docker socket can start a
      # privileged container, and what that container can read is whatever the
      # VM mounts, so this is the only place the question gets decided. The
      # cost is bind mounts in unrelated `docker run` invocations.
      #
      # pi's --allow-forge does not rest on this setting: it grants forge's VM
      # (nix/pkgs/forge/vm.nix) and refuses unless that instance declares the
      # same property, which is checked against the instance at grant time.
      mounts = [ "none" ];
    };
  };

  home.packages = with pkgs; [
    argocd
    coder
    forge
    linear-cli
    opencode
    pdm
    pulumi
    pkgs.pulumiPackages.pulumi-python
  ];

  # The cluster count here is load-bearing twice over: forge assigns each
  # cluster one API port from the window its VM forwards and refuses a config
  # past the end of it, and guest.nix sizes the guest's inotify limits for this
  # many kind nodes.
  xdg.configFile."forge/forge.yaml".source = ../../pkgs/forge/forge.yaml;
  # pi-broker brings a small instance up with this one instead.
  xdg.configFile."forge/forge-small.yaml".source = ../../pkgs/forge/forge-small.yaml;

  # Coder remote development SSH config
  programs.ssh.matchBlocks = {
    "coder.*" = {
      extraOptions = {
        ConnectTimeout = "0";
        StrictHostKeyChecking = "no";
        UserKnownHostsFile = "/dev/null";
        LogLevel = "ERROR";
      };
      proxyCommand = ''coder --global-config "$HOME/Library/Application Support/coderv2" ssh --stdio --ssh-host-prefix coder. %h'';
    };
    "*.coder" = {
      extraOptions = {
        ConnectTimeout = "0";
        StrictHostKeyChecking = "no";
        UserKnownHostsFile = "/dev/null";
        LogLevel = "ERROR";
      };
    };
  };

  programs.ssh.extraConfig = lib.mkAfter ''
    Match host *.coder !exec "coder connect exists %h"
      ProxyCommand coder --global-config "$HOME/Library/Application Support/coderv2" ssh --stdio --hostname-suffix coder %h
  '';
}
