# this module is a catch all for general development things. As needed I will
# break related configurations out of this file into its own module., I also
# try to not get carried away for the sake of it.

{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.dev;
in
{
  options.hmFoundry.dev = {
    enable = mkEnableOption "General development utilities and configuration";
  };

  config = mkIf cfg.enable {
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
    home.packages = with pkgs; [
      act # run github actions locally
      age # better encryption
      ansible # config management
      aspell # spell check
      aspellDicts.en
      aspellDicts.en-computers
      aspellDicts.en-science
      awscli2 # interacting with AWS
      bash # want my modern bash
      bc # the classic calculator
      clang
      cmake
      coreutils-full
      cowsay # cows keep me informed
      ctags # for navigating within NeoVim
      direnv
      dnsutils # dig
      docker-compose
      dos2unix # windows line endings => unix
      entr # run arbitrary commands when files change
      envsubst
      fd # an easier to use `find`
      file # what type of file is this?
      findutils
      fortune # fun tidbits
      glances # system monitor
      go-jira # cli for interacting with Jira
      gron # make JSON greppable
      htmlq # like jq, but for HTML
      htop # system diagnostics
      ispell # spell checking
      jq # easy json formatting
      k9s # stylish kubernetes management
      kind # local k8s dev
      kubectl
      kubectx
      kubernetes-helm # helm
      lesspipe # auto piping into less
      lorri
      lsof # how is this not in the base system?
      lz4
      man-pages # developer documentation
      mosh # better ssh
      my-scripts # personal scripts. See `scripts` and `overlay` folder
      ncspot # cursors spotify client
      niv # nix package pinning
      nixfmt # formatter for nix files
      nixpkgs-fmt # formatter for nix
      nixpkgs-review # easily dev on nixpkgs
      nmap # network mapping and scanning
      openvpn # covering my tracks
      pixz # parallel (de)compresser for xz
      postgresql # _the_ DB
      proselint # A linter for prose
      pv # pipe progress
      ranger # cli file browser
      ripgrep # recursively searches directories for a regex pattern
      rsync # use an upto date one, not whatever ships with the OS
      shellcheck # linting bash scripts
      shfmt # shell (bash) formatting
      silver-searcher # (ag) A code-searching tool similar to ack, but faster
      slack-cli # bash based cli for interacting with slack
      sops # secret management
      squashfsTools # create and unpack squashfs
      step-cli # working with CAs
      tree # directory listing
      unzip # unzip things
      viddy # Modern watch command.
      w3m # browse the web from the cli, like it was meant to be
      #weechat # IRC client
      watch
      wget # get a file from the internet
      xclip # copy something to the clipboard
      xlsx2csv # useful for bash automation of buissness flows
      xz # compression format
      youtube-dl # download videos from youtube and others
      yq-go # like jq, but for yaml
      #zbar # barcode reader, mostly used to import OTP into pass # todo: BROKEN
    ]

    # in reality isLinux == isNixos for me. I don't run nix on any linux
    # machines currently.
    ++ optionals stdenv.isLinux [
      atop # system monitoring
      babashka # a Clojure babushka for the grey areas of Bash
      calcurse # cli calendar
      cifs-utils # todo: why do I need this?
      discord # am I cool now?
      golden-cheetah # cycling analytics
      inotify-tools # watch the file system for changes
      insomnia # rest client
      ltrace # trace library calls
      makemkv # rip DVDs
      molly-guard # prevent footguns from runing my day
      qemu_full
      remmina # remote desktop client
      smbnetfs # todo: why do I need this?
      steam # games # todo: I should break this out into gaming.nix
      virtmanager # manage KVM
      zoom-us # pandemic life
    ]

    ++ optionals stdenv.isDarwin [
      octo # octopus cli
    ];
  };
}
