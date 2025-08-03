# Development tools and configuration
# Used by profiles that need development capabilities

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

    # Development packages organized by feature flags
    home.packages =
      with pkgs;
      let
        cfg = config.hmFoundry.features;

        # Core development tools (always included when isDevelopment = true)
        coreDevTools = [
          bashInteractive
          ctags
          direnv
          envsubst
          jq
          my-scripts
          ripgrep
          fd
          tree
          bat
          curl
          wget
          file
          gnumake
          gnused
          shellcheck
          shfmt
          yq-go
          gron
          htmlq
        ];

        # Kubernetes development tools
        kubernetesTools = optionals cfg.isKubernetes [
          k9s
          kubectl
          kubectl-node-shell
          kubectx
          kubernetes-helm
          kind
        ];

        # AWS and cloud tools
        awsTools = optionals cfg.isAWS [
          awscli2
        ];

        # Terraform and infrastructure tools
        terraformTools = optionals cfg.isTerraform [
          terraform_1
        ];

        # Docker and container tools
        dockerTools = optionals cfg.isDocker [
          docker-compose
        ];

        # Media processing and content creation tools
        mediaDevTools = optionals cfg.isMediaDev [
          ffmpeg
          exiftool
          diff-pdf
          master.yt-dlp
        ];

        # Document processing and writing tools
        documentTools = optionals cfg.isDocuments [
          aspell
          aspellDicts.en
          aspellDicts.en-computers
          aspellDicts.en-science
          proselint
          dos2unix
          ispell
        ];

        # System administration and monitoring tools
        systemAdminTools = optionals cfg.isSystemAdmin [
          htop
          lsof
          nettools
          dnsutils
          nmap
          mosh
        ];

        # Advanced monitoring and diagnostic tools
        monitoringTools = optionals cfg.isMonitoring [
          glances
          viddy
          watch
          pv
        ];

        # Security and secrets management tools
        securityTools = optionals cfg.isSecurity [
          age
          sops
          openvpn
          zbar
        ];

        # Performance analysis and optimization tools
        performanceTools = optionals cfg.isPerformance [
          parallel
          mbuffer
          lz4
          lzop
          pixz
          xz
        ];

        # Nix development and packaging tools
        nixDevTools = optionals cfg.isNixDev [
          nix-index
          nixfmt-rfc-style
          nixpkgs-fmt
          nixpkgs-review
        ];

        # Additional Clojure development tools
        clojureDevTools = optionals cfg.isClojureDev [
          babashka-scripts
        ];

        # Additional general development utilities
        additionalDevTools = [
          act # run github actions locally
          master.aider-chat-full # ai tooling
          clang
          cmake
          cookiecutter
          fswatch
          grpcurl
          lorri
          postgresql
          rsync
          silver-searcher
          visidata
          bc
          berkeley-mono
          cowsay
          entr
          fortune
          lesspipe
          pciutils
          pragmata-pro
          ranger
          squashfsTools
          unzip
          w3m
          xclip
          xlsx2csv
        ];

        # Linux-specific development tools
        linuxDevTools = optionals stdenv.isLinux [
          atop
          babashka
          calcurse
          inotify-tools
          ltrace
          molly-guard
          qemu_full
          virt-manager
        ];
      in
      coreDevTools
      ++ kubernetesTools
      ++ awsTools
      ++ terraformTools
      ++ dockerTools
      ++ mediaDevTools
      ++ documentTools
      ++ systemAdminTools
      ++ monitoringTools
      ++ securityTools
      ++ performanceTools
      ++ nixDevTools
      ++ clojureDevTools
      ++ additionalDevTools
      ++ linuxDevTools;

    programs = {
      bat = {
        enable = true;
        config = {
          theme = "gruvbox-dark";
        };
      };
      direnv = {
        enable = true;
        nix-direnv = {
          enable = true;
        };
      };
    };
  };
}
