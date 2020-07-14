# this file is for packages the don't need an entire file for configuration.
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    my-scripts # personal scripts. See `scripts` and `overlay` folder

    ag # A code-searching tool similar to ack, but faster
    ansible # system administration automation
    atop # system monitoring
    awscli # interacting with AWS
    bc # the classic calculator
    calcurse # cli calendar
    cifs-utils # todo: why do I need this?
    cowsay # cows keep me informed
    ctags # for navigating within NeoVim
    direnv
    dnsutils # dig
    docker-compose
    dos2unix # windows line endings => unix
    dropbox-cli # dropbox and the cli to interact with it
    file # what type of file is this?
    fortune # fun tidbits
    ghc # Glasgow Haskell compiler
    go-jira # cli for interacting with Jira
    golden-cheetah # cycling analytics
    htop # system diagnostics
    inotify-tools # watch the file system for changes
    insomnia # rest client
    ispell # spell checking
    jq # easy json formatting
    lesspipe # auto piping into less
    libreoffice # getting things done
    lsof # how is this not in the base system?
    ltrace # trace library calls
    manpages # developer documentation
    molly-guard # prevent footguns from runing my day
    mosh # better ssh
    niv # nix package pinning
    nixfmt # formatter for nix files
    nixpkgs-fmt # formatter for nix
    nmap # network mapping and scanning
    openvpn # covering my tracks
    pass-otp # pass + otp extension
    passff-host # firefox plugin host extension
    pixz # parallel (de)compresser for xz
    proselint # A linter for prose
    pv # pipe progress
    ranger # cli file browser
    remmina # remote desktop client
    ripgrep # recursively searches directories for a regex pattern
    shellcheck # linting bash scripts
    shfmt # shell (bash) formatting
    smbnetfs # todo: why do I need this?
    squashfsTools # create and unpack squashfs
    st # lightweight terminal
    stack # Haskell build tooling
    steam # games # todo: I should break this out into gaming.nix
    tree # directory listing
    unzip # unzip things
    virtmanager # manage KVM
    w3m # browse the web from the cli, like it was meant to be
    weechat # IRC client
    wget # get a file from the internet
    xclip # copy something to the clipboard
    xz # compression format
    youtube-dl # download videos from youtube and others
    yq-go # like jq, but for yaml
    zathura # lightweight PDF viewer
    zbar # barcode reader, mostly used to import OTP into pass
    zoom-us # video confrence

    # hashi tools, first and third party
    #
    # I am not sure the value of having these randomly available on PATH. In
    # any real use case they are going to be pinned within the project
    # repository. It wouls still feel weird to not having hace them always
    # available.
    nomad
    packer
    terraform # infrastructure as code
    terraform-docs # auto documentation generation
    terragrunt # more tooling for tf
    tflint # better terraform linter
    tfsec #  static analysis of terraform
    vault
  ];

}
