# This is a catchall for configuration items that are common across all
# machines and at this time do not make sense to break out into their own file.
{ config, pkgs, ... }:

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
    config.boot.kernelPackages.perf
  ];

  # Select internationalisation properties.
  i18n = { defaultLocale = "en_US.UTF-8"; };
  console = {
    # apply the X keymap to the console keymap, which affects virtual consoles
    # such as tty.
    useXkbConfig = true;
  };

  environment.pathsToLink = [ "/libexec" "/share/zsh" ];
  services = {
    xserver = {
      enable = true;
      xkb = {
        options = "ctrl:nocaps"; # make caps lock a control key
      };
      #displayManager = { defaultSession = "none+i3"; };
      desktopManager = { xterm.enable = false; };
    };
    udev = {
      packages = [ pkgs.yubikey-personalization ];
      extraRules = ''
        # UDEV rules for Teensy USB devices
        ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789B]?", ENV{ID_MM_DEVICE_IGNORE}="1"
        ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789A]?", ENV{MTP_NO_PROBE}="1"
        SUBSYSTEMS=="usb", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789ABCD]?", MODE:="0666"
        KERNEL=="ttyACM*", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789B]?", MODE:="0666"
      '';
    };
    pcscd.enable = true;
    openssh.enable = true;
    xserver = {
      autorun = true;
      windowManager.i3.enable = true;
    };
    fstrim.enable = true;
    printing = {
      enable = true;
      drivers = [ pkgs.hplip ];
    };
  };

  programs = {
    ssh = {
      startAgent = false;
    };
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
    tmp = {
      cleanOnBoot = true;
      useTmpfs = true;
    };
    kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
    extraModulePackages = with config.boot.kernelPackages; [
      perf
      systemtap
    ];
  };
  nix = {
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 35d";
    };
    settings = {
      auto-optimise-store = true;
    };
    buildMachines = [
      {
        hostName = "tiger.dmz.1ella.com";
        sshUser = "svc.deploy";
        systems = [ "x86_64-linux" "aarch64-linux" ];
        maxJobs = 8;
        speedFactor = 10; # prefer this builder
        supportedFeatures = [ "benchmark" "big-parallel" ];
      }
    ];
    extraOptions = ''
      builders-use-substitutes = true
      experimental-features = nix-command flakes
      min-free = ${toString (1 * 1024 * 1024 * 1024)}
      max-free = ${toString (25 * 1024 * 1024 * 1024)}
      # these two options prevent nix-shells from being GCed.
      keep-derivations = true
      keep-outputs = true

    '';
    distributedBuilds = true;
  };

  virtualisation.vmVariant = {
    # following configuration is added only when building VM with build-vm
    virtualisation = {
      memorySize = 4096;
      cores = 2;
    };
  };

  # TODO: fonts should go somewhere else
  fonts.packages = with pkgs; [
    gyre-fonts
    textfonts
  ];

}
