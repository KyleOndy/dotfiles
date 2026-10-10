# Base home-manager configuration for work macOS environments
# The desktop profile is imported via mkDarwinSystem
# This file provides macOS-specific overrides and allows work-specific extensions via work-home.nix
{
  lib,
  pkgs,
  config,
  osConfig,
  ...
}:
{
  imports = [ ];

  nix.gc = {
    automatic = true;
    options = "--delete-older-than 7d";
  };

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

  # work-config sets the global email to the work address. The repos under
  # ~/src/kyleondy, these dotfiles included, are personal and public, so they
  # commit as the personal one. The trailing slash makes git append `**`,
  # which covers each worktree's gitdir under .bare (git-config(1),
  # Conditional includes).
  programs.git.includes = [
    {
      condition = "gitdir:${config.home.homeDirectory}/src/kyleondy/";
      contents.user.email = "kyle@ondy.org";
    }
  ];

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
    # without the value (once granted: the gate below keeps an ungranted
    # session from resolving it at all).
    pi-coding-agent.sandbox.envFromCommands.KAGI_API_KEY = "/usr/bin/security find-generic-password -s pi -a kagi -w";
    pi-coding-agent.sandbox.envGrantGates.KAGI_API_KEY = "kagi";
    # The catalog and the seats are sops secrets (nix/secrets/work-mac.yaml),
    # since the model ids in them are private. work-config appends its
    # gateway and loopback providers to trustedProviders, whose names are
    # private too.
    pi-coding-agent.modelsJsonFile = osConfig.sops.secrets.pi_models_json.path;
    pi-coding-agent.seatsFile = osConfig.sops.secrets.pi_seats.path;
    pi-coding-agent.secretsSource = "nix/secrets/work-mac.yaml";
    pi-coding-agent.trustedProviders = [ "mcloud" ];
    pi-coding-agent.coordinator = {
      enable = true;
      # The one host with forge.
      forge.enable = true;
    };

    claude-code.enable = true;
    codex.enable = true;
    agent-context.skills = [
      {
        name = "forge-debug";
        source = ./skills/forge-debug.md;
        isFile = true;
      }
      {
        name = "pi-delegate";
        source = ./skills/pi-delegate.md;
        isFile = true;
        # Written around Claude Code's tools and token budget.
        harnesses = [ "claude-code" ];
      }
    ];
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
  programs.ssh.settings = {
    "coder.*" = {
      ConnectTimeout = 0;
      StrictHostKeyChecking = false;
      UserKnownHostsFile = "/dev/null";
      LogLevel = "ERROR";
      ProxyCommand = ''coder --global-config "$HOME/Library/Application Support/coderv2" ssh --stdio --ssh-host-prefix coder. %h'';
    };
    "*.coder" = {
      ConnectTimeout = 0;
      StrictHostKeyChecking = false;
      UserKnownHostsFile = "/dev/null";
      LogLevel = "ERROR";
    };
  };

  programs.ssh.extraConfig = lib.mkAfter ''
    Match host *.coder !exec "coder connect exists %h"
      ProxyCommand coder --global-config "$HOME/Library/Application Support/coderv2" ssh --stdio --hostname-suffix coder %h
  '';
}
