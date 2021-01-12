# This is a catchall for configuration items that are common across all
# machines and at this time do not make sense to break out into their own file.
{ pkgs, ... }:

{
  # Set your time zone.
  time.timeZone = "America/New_York";

  environment.systemPackages = with pkgs; [
    # these are the bare minimum needed to bootstrap into my system
    curl # get whatever random files / pgp keys I need
    gitAndTools.git # to clone the dotfiles repo
    gnumake # to apply dotfiles
    rsync # to sync from other machines
    neovim # to edit files with
  ];

  # Select internationalisation properties.
  i18n = { defaultLocale = "en_US.UTF-8"; };
  console = {
    font = "Iosevka";
    #KeyMap = "us";
    # apply the X keymap to the console keymap, which affects virtual consoles
    # such as tty.
    useXkbConfig = true;
  };

  environment.pathsToLink = [ "/libexec" "/share/zsh" ];
  services = {
    xserver = {
      enable = true;
      xkbOptions = "ctrl:nocaps"; # make caps lock a control key
      displayManager = { defaultSession = "none+i3"; };
      desktopManager = { xterm.enable = false; };
    };
    udev.packages = [ pkgs.yubikey-personalization ];
    pcscd.enable = true;
    openssh.enable = true;
    xserver = {
      autorun = true;
      windowManager.i3.enable = true;
    };
    fstrim.enable = true;
    printing.enable = true;
  };

  programs = {
    ssh.startAgent = false;
    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };
    mosh.enable = true;
    less = {
      enable = true;
      envVariables = { LESS = "--quit-if-one-screen --RAW-CONTROL-CHARS --no-init"; };
    };
  };
  # todo: will this work, or do I need to pass in explicit git hash?
  #environment.etc."nixos/active".text = config.system.nixos.label;
  environment.sessionVariables = {
    # todo: does this still hold?
    # need to set this at the system level since i3 is started before I can login as a user and environment variables I set are within child processes.
    TERMINAL = "st";
  };

  # Enable sound.
  sound = {
    enable = true;
    mediaKeys = { enable = true; };
  };
  hardware.pulseaudio.enable = true;
  boot = {
    cleanTmpDir = true;
    tmpOnTmpfs = true;
    kernelPackages = pkgs.linuxPackages_latest;
  };

  nix = {
    package = pkgs.nixUnstable;
    trustedUsers = [ "root" "kyle" ];
    autoOptimiseStore = true;
    nixPath = [
      "nixpkgs=${pkgs.path}"
    ];
    optimise.automatic = true;
    extraOptions = ''
      builders-use-substitutes = true
      experimental-features = nix-command flakes
    '';
    distributedBuilds = true;
    buildMachines = [
      {
        hostName = "tau.lan.509ely.com";
        systems = [ "x86_64-linux" "aarch64-linux" ];
        maxJobs = 6;
        speedFactor = 10; # prefer this builder
        supportedFeatures = [ "benchmark" "big-parallel" ];
      }
      {
        hostName = "w1.dmz.509ely.com";
        systems = [ "x86_64-linux" "aarch64-linux" ];
        maxJobs = 1;
        speedFactor = 5;
        supportedFeatures = [ ];
      }
      {
        hostName = "w2.dmz.509ely.com";
        systems = [ "x86_64-linux" "aarch64-linux" ];
        maxJobs = 1;
        speedFactor = 5;
        supportedFeatures = [ ];
      }
      {
        hostName = "w3.dmz.509ely.com";
        systems = [ "x86_64-linux" "aarch64-linux" ];
        maxJobs = 1;
        speedFactor = 5;
        supportedFeatures = [ ];
      }
      #{
      #  hostName = "eu.nixbuild.net";
      #  system = "x86_64-linux";
      #  maxJobs = 100;
      #  speedFactor = 1;
      #  supportedFeatures = [ "benchmark" "big-parallel" ];
      #}
    ];
  };
}
