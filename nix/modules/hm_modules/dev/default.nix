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
      aspell # spell check
      aspellDicts.en
      aspellDicts.en-computers
      aspellDicts.en-science
      awscli2 # interacting with AWS
      bashInteractive # want my modern bash
      bc # the classic calculator
      berkeley-mono # font
      clang
      cmake
      cookiecutter
      coreutils-full
      cowsay # cows keep me informed
      ctags # for navigating within NeoVim
      curl # get whatever random files / pgp keys I need
      direnv
      dnsutils # dig
      docker-compose
      dos2unix # windows line endings => unix
      entr # run arbitrary commands when files change
      envsubst
      exiftool # work with exif data
      fd # an easier to use `find`
      ffmpeg # video utilities
      file # what type of file is this?
      findutils
      fortune # fun tidbits
      fswatch
      ghostty # terminal from mitchellh
      glances # system monitor
      gnumake # make
      gnused # sed
      groff # man pages
      gron # make JSON greppable
      grpcurl # like curl, but for gRPC
      htmlq # like jq, but for HTML
      htop # system diagnostics
      ispell # spell checking
      jq # easy json formatting
      k9s # stylish kubernetes management
      keymapp # zsa keyboard config
      kind # local k8s dev
      kubectl
      kubectl-node-shell # host access to k8s host
      kubectx
      kubernetes-helm # helm
      lesspipe # auto piping into less
      lorri
      lsof # how is this not in the base system?
      lz4
      lzop # fast file compresser, use for zfs transfers
      man-pages # developer documentation
      mbuffer # buffer data streams, use for zfs transfers
      mosh # better ssh
      my-scripts # personal scripts. See `scripts` and `overlay` folder
      ncspot # cursors spotify client
      nix-index # find packages
      nixfmt-rfc-style # formatter for nix files
      nixpkgs-fmt # formatter for nix
      nixpkgs-review # easily dev on nixpkgs
      nmap # network mapping and scanning
      openvpn # covering my tracks
      parallel # name says it all
      pciutils # lspci
      pixz # parallel (de)compresser for xz
      postgresql # _the_ DB
      pragmata-pro
      proselint # A linter for prose
      pv # pipe progress
      ranger # cli file browser
      ripgrep # recursively searches directories for a regex pattern
      rsync # use an upto date one, not whatever ships with the OS
      shellcheck # linting bash scripts
      shfmt # shell (bash) formatting
      silver-searcher # (ag) A code-searching tool similar to ack, but faster
      sops # secret management
      squashfsTools # create and unpack squashfs
      terraform_1
      tree # directory listing
      unzip # unzip things
      viddy # Modern watch command.
      visidata # vd tool for viewing structured data
      vlc # watch things
      w3m # browse the web from the cli, like it was meant to be
      watch
      wget # get a file from the internet
      xclip # copy something to the clipboard
      xlsx2csv # useful for bash automation of buissness flows
      xz # compression format
      yq-go # like jq, but for yaml
      master.yt-dlp # download videos from youtube and others
      zbar # barcode reader, mostly used to import OTP into pass
    ]

    # in reality isLinux == isNixos for me. I don't run nix on any linux
    # machines currently.
    ++ optionals stdenv.isLinux [
      atop # system monitoring
      babashka # a Clojure babushka for the grey areas of Bash
      calcurse # cli calendar
      inotify-tools # watch the file system for changes
      ltrace # trace library calls
      molly-guard # prevent footguns from runing my day
      qemu_full
      virt-manager # manage KVM
    ];
  };
}
