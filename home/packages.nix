# this file is for packages the don't need an entire file for configuration.
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    my-scripts # my personal scripts

    ansible # system administration automation
    awscli # interacting with AWS
    bc # the classic calculator
    calcurse # cli calendar
    cifs-utils # todo: why do I need this?
    cowsay # cows keep me informed
    ctags # for navigating within NeoVim
    direnv
    dnsutils # dig
    docker-compose
    dropbox-cli # dropbox and the cli to interact with it
    file # what type of file is this?
    fortune # fun tidbits
    ghc # Glasgow Haskell compiler
    go-jira # cli for interacting with Jira
    htop # system diagnostics
    ispell # spell checking
    jetbrains.idea-community
    jq # easy json formatting
    lesspipe # auto piping into less
    libreoffice # getting things done
    lsof # how is this not in the base system?
    ltrace # trace library calls
    manpages # developer documentation
    mosh # better ssh
    nixfmt # formatter for nix files
    nixpkgs-fmt # formatter for nix
    pass-otp # pass + otp extension
    ranger # cli file browser
    remmina # remote desktop client
    shellcheck # linting bash scripts
    slack # chat
    smbnetfs # todo: why do I need this?
    st # lightweight terminal
    stack # Haskell build tooling
    terraform # infrastructure as code
    terraform-docs # auto documentation generation
    tflint # better terraform linter
    tree # directory listing
    unzip # unzip things
    weechat # IRC client
    wget # get a file from the internet
    xclip # copy something to the clipboard
    xz # compression format
    yq-go # like jq, but for yaml
    zathura # lightweight PDF viewer

    #hashi tools
    packer
    terraform
    vault
  ];

}
