# this file is for packages the don't need an entire file for configuration.
{ pkgs, lib, ... }:
let
  inherit (pkgs) stdenv;
  inherit (lib) optionals;
in
{
  home.packages = with pkgs; [
    my-scripts # personal scripts. See `scripts` and `overlay` folder
    ag # A code-searching tool similar to ack, but faster
    ansible # system administration automation
    aspell # spell check
    aspellDicts.en
    aspellDicts.en-computers
    aspellDicts.en-science
    awscli2 # interacting with AWS
    bc # the classic calculator
    clang
    cmake
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
    fortune # fun tidbits
    ghc # Glasgow Haskell compiler
    glances # system monitor
    go-jira # cli for interacting with Jira
    gron # make JSON greppable
    htop # system diagnostics
    ispell # spell checking
    jq # easy json formatting
    k9s # stylish kubernetes management
    kubectx
    lesspipe # auto piping into less
    lsof # how is this not in the base system?
    lz4
    manpages # developer documentation
    mosh # better ssh
    ncspot # cursors spotify client
    niv # nix package pinning
    nixfmt # formatter for nix files
    nixpkgs-fmt # formatter for nix
    nixpkgs-review # easily dev on nixpkgs
    nmap # network mapping and scanning
    openvpn # covering my tracks
    (pass.withExtensions (ext: [ ext.pass-otp ])) # pass + otp extension
    passff-host # firefox plugin host extension
    pixz # parallel (de)compresser for xz
    proselint # A linter for prose
    pv # pipe progress
    ranger # cli file browser
    ripgrep # recursively searches directories for a regex pattern
    rsync # use an upto date one, not whatever ships with the OS
    shellcheck # linting bash scripts
    shfmt # shell (bash) formatting
    slack-cli # bash based cli for interacting with slack
    squashfsTools # create and unpack squashfs
    st # lightweight terminal
    stack # Haskell build tooling
    step-cli # working with CAs
    tree # directory listing
    unzip # unzip things
    w3m # browse the web from the cli, like it was meant to be
    #weechat # IRC client
    wget # get a file from the internet
    xclip # copy something to the clipboard
    xlsx2csv # useful for bash automation of buissness flows
    xz # compression format
    youtube-dl # download videos from youtube and others
    yq-go # like jq, but for yaml
    zathura # lightweight PDF viewer
    zbar # barcode reader, mostly used to import OTP into pass
    bash_5 # want my modern bash
    coreutils-full
    findutils
    lorri
    watch
  ]

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
    molly-guard # prevent footguns from runing my day
    qemu-utils
    qemu_full
    remmina # remote desktop client
    smbnetfs # todo: why do I need this?
    steam # games # todo: I should break this out into gaming.nix
    virtmanager # manage KVM
    zoom-us # pandemic life
  ];

  #++ optionals stdenv.isDarwin
  #[];
}
