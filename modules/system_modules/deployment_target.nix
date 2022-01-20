{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.deployment_target;
in
{
  options.systemFoundry.deployment_target = {
    enable = mkEnableOption ''
      Basic configuration which allows the node to be comply with assumptions I
      made about the target node.

      This is also a kind of catch all when I want to unilaterally deploy
      something out to all managed nodes.
    '';
  };

  config = mkIf cfg.enable {

    environment.systemPackages = with pkgs; [
      bat # better cat
      dnsutils # for dig
      fd # better find
      git # working this repos locally
      glances # general monitoring
      htop # lighter weight general monitoring
      mosh # persistent ssh like shell
      neovim # file editing
      ripgrep # finding files
      rsync # syncing files
    ];

    users = {
      defaultUserShell = pkgs.bash_5;
      mutableUsers = false;
      users."svc.deploy" = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        hashedPassword =
          "$6$XTNiJhQm1$D3M90syVNZdTazCOZIAF8TLK/hD4oSi3Xdst62dCkWR44ia3rujnPx.yWT6BaU4tvu1im5nR20WcjWnhPMTIV/";
        # todo: make a key for just deploys
        openssh.authorizedKeys.keys = [
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDZq6q45h3OVj7Gs4afJKL7mSz/bG+KMG0wIOEH+wXmzDdJ0OX6DLeN7pua5RAB+YFbs7ljbc8AFu3lAzitQ2FNToJC1hnbLKU0PyoYNQpTukXqP1ptUQf5EsbTFmltBwwcR1Bb/nBjAIAgi+Z54hNFZiaTNFmSTmErZe35bikqS314Ej60xw2/5YSsTdqLOTKcPbOxj2kulznM0K/z/EDcTzGqc0Mcnf51NtzxlmB9NR4ppYLoi7x+rVWq04MbdAmZK70p5ndRobqYSWSKq+WDUAt2+CiTm6ItDowTLuo3zjHyYV1eCnB35DdakKVldIHrQyhmhbf5hJi6Ywx6XCzlFoNpkl/++RrJT2rf0XpGdlRoLQoKFvNRfnO4LI499SIfFb9Pwq7LhF1C1kTmshN/9S44d6VCCYXLE4uS8OPv7IXxUvFQZaIKCbomd2FzXxUwf4lg2gSlczysgDaVsMAUvlfDVgTFX8Xt1LFl3DqNtUiUpa9+Jnst/jCqqOBf3e8= kyle@alpha"
        ];
      };
    };
    services = {
      openssh = {
        enable = true;
        permitRootLogin = "no";
      };
      logind.extraConfig = ''
        RuntimeDirectorySize=8G
      '';
    };

    nixpkgs.config.allowUnfree = true;
    nix = {
      package = pkgs.nixStable;
      trustedUsers = [ "root" "@wheel" ]; # todo: security issue?
      nixPath = [ "nixpkgs=${pkgs.path}" ];
      autoOptimiseStore = true;
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };
      # Free up to 1GiB whenever there is less than 100MiB left.
      extraOptions = ''
        builders-use-substitutes = true
        experimental-features = nix-command flakes
        min-free = ${toString (100 * 1024 * 1024)}
        max-free = ${toString (1024 * 1024 * 1024)}
      '';
      distributedBuilds = true;
      buildMachines = [
        {
          hostName = "tiger.lan.509ely.com";
          sshUser = "svc.deploy";
          systems = [ "x86_64-linux" "aarch64-linux" ];
          maxJobs = 8;
          speedFactor = 10; # prefer this builder
          supportedFeatures = [ "benchmark" "big-parallel" ];
        }
      ];
    };
    security = {
      sudo.wheelNeedsPassword = false;
      acme = {
        # so I do not need to set it in every module
        acceptTerms = true;
        email = "kyle@ondy.org";
      };
    };
    sops = {
      # this file path _feels_ suspect, but works
      defaultSopsFile = ./../../secrets/secrets.yaml;
    };
  };
}
