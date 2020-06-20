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
  ];

  # Select internationalisation properties.
  i18n = { defaultLocale = "en_US.UTF-8"; };
  console = {
    font = "Hack";
    #KeyMap = "us";
    # apply the X keymap to the console keymap, which affects virtual consoles
    # such as tty.
    useXkbConfig = true;
  };

  environment.pathsToLink = [ "/libexec" "/share/zsh" ];
  services.xserver = {
    enable = true;
    xkbOptions = "ctrl:nocaps"; # make caps lock a control key
    displayManager = { defaultSession = "none+i3"; };
    desktopManager = { xterm.enable = false; };
  };
  # yubikey
  services.udev.packages = [ pkgs.yubikey-personalization ];
  services.pcscd.enable = true;

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

  services.xserver = {
    autorun = true;
    windowManager.i3.enable = true;
  };

  # Enable the OpenSSH daemon.
  services.openssh = { enable = true; };
  # Enable sound.
  sound = {
    enable = true;
    mediaKeys = { enable = true; };
  };
  hardware.pulseaudio.enable = true;
  boot = {
    cleanTmpDir = true;
    kernelPackages = pkgs.linuxPackages_latest;
  };
}
