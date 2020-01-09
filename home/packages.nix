# this file is for packages the don't need an entire file for configuration.
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    ansible     # system administration automation
    awscli      # interacting with AWS
    cifs-utils  # todo: why do I need this?
    smbnetfs    # todo: why do I need this?
    cowsay      # cows keep me informed
    ctags       # for navigating within NeoVim
    dnsutils    # dig
    docker-compose
    dropbox-cli # dropbox and the cli to interact with it
    file        # what type of file is this?
    fortune     # fun tidbits
    fortune     # quotations
    ghc         # Glasgow Haskell compiler
    htop        # system diagnostics
    jetbrains.idea-community
    jq          # easy json formatting
    lesspipe    # auto piping into less
    libreoffice # gettings things done
    lsof        # how is this not in the base system?
    mosh        # better ssh
    nixfmt      # formatter for nix files
    pass-otp    # pass + otp extension
    ranger      # cli file browser
    remmina     # remote desktop client
    shellcheck  # linting bash scripts
    signal-desktop
    slack       # chat
    st          # lightweight terminal
    stack       # Haskell build tooling
    terraform   # infrastructure as code
    tree        # directory listing
    unzip       # unzip things
    weechat     # IRC client
    wget        # get a file from the internet
    xclip       # copy something to the clipboard
    zathura     # lightweight PDF viewer
  ];

}
