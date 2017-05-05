#!/bin/bash
set -eo pipefail

# install.sh
#  This script installs my basic setup for a debian laptop

# get the user that is not root
# TODO: makes a pretty bad assumption that there is only one other user
USERNAME=$(find /home/* -maxdepth 0 -printf "%f" -type d || echo "$USER")
export DEBIAN_FRONTEND=noninteractive

check_is_sudo() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit
  fi
}

# sets up apt sources
# assumes you are going to use debian stretch
setup_sources() {
  apt-get update
  apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    dirmngr \
    gnupg2 \
    software-properties-common

cat <<-EOF > /etc/apt/sources.list
  deb http://httpredir.debian.org/debian stretch main contrib non-free
  deb-src http://httpredir.debian.org/debian/ stretch main contrib non-free

  deb http://httpredir.debian.org/debian/ stretch-updates main contrib non-free
  deb-src http://httpredir.debian.org/debian/ stretch-updates main contrib non-free

  deb http://security.debian.org/ stretch/updates main contrib non-free
  deb-src http://security.debian.org/ stretch/updates main contrib non-free

  deb http://download.virtualbox.org/virtualbox/debian stretch contrib
EOF

  # looking up the actual key since if someone got control of the website the key is hosted on,
  # they could switch the key

  # add docker gpg key
  # todo: use full key
  apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 8D81803C0EBFCD88
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"

  # thought bot
  # todo: see if key is on public keyserver, refrence actaul key
  curl https://apt.thoughtbot.com/thoughtbot.gpg.key | apt-key add -
  echo "deb http://apt.thoughtbot.com/debian/ stable main" | tee /etc/apt/sources.list.d/thoughtbot.list

  # virtualbox
  # todo: see if key is on public keyserver, refrence actaul key
  curl https://www.virtualbox.org/download/oracle_vbox_2016.asc | apt-key add -

  # turn off translations, speed up apt-get update
  mkdir -p /etc/apt/apt.conf.d
  echo 'Acquire::Languages "none";' > /etc/apt/apt.conf.d/99translations
}

# installs base packages
# the utter bare minimal shit
base() {
  apt-get update
  apt-get -y upgrade

  apt-get install -y \
    adduser \
    alsa-utils \
    asciinema \
    atop \
    automake \
    bash-completion \
    bc \
    build-essential \
    ca-certificates \
    coreutils \
    cowsay \
    curl \
    dnsutils \
    file \
    findutils \
    fonts-fantasque-sans \
    gcc \
    git \
    gnupg \
    gnupg-agent \
    gnupg2 \
    grep \
    gzip \
    hostname \
    htop \
    iceweasel \
    iptables \
    jq \
    less \
    lsof \
    lynx \
    make \
    mosh \
    mount \
    neovim \
    net-tools \
    network-manager \
    nload \
    nmap \
    openvpn \
    pass \
    pcscd \
    pinentry-curses \
    python3-pip \
    rcm \
    rsync \
    rxvt-unicode-256color \
    s3cmd \
    scdaemon \
    silversearcher-ag \
    ssh \
    strace \
    sudo \
    tar \
    tmux \
    tree \
    tzdata \
    unzip \
    wicd-curses \
    xclip \
    xsel \
    zip \
    zsh

  # install tlp with recommends
  apt-get install -y tlp tlp-rdw

  setup_sudo

  apt-get autoremove
  apt-get autoclean
  apt-get clean

  install_docker
  install_scripts
}

# setup sudo for a user
# because fuck typing that shit all the time
# just have a decent password
# and lock your computer when you aren't using it
# if they have your password they can sudo anyways
# so its pointless
# i know what the fuck im doing ;)
setup_sudo() {
  # add user to sudoers
  adduser "$USERNAME" sudo

  # add user to systemd groups
  # then you wont need sudo to view logs and shit
  gpasswd -a "$USERNAME" systemd-journal
  gpasswd -a "$USERNAME" systemd-network

  # add go path to secure path
  { \
    echo -e 'Defaults  secure_path="/usr/local/go/bin:/home/jessie/.go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'; \
    echo -e 'Defaults  env_keep += "ftp_proxy http_proxy https_proxy no_proxy GOPATH EDITOR"'; \
    echo -e "${USERNAME} ALL=(ALL) NOPASSWD:ALL"; \
    echo -e "${USERNAME} ALL=NOPASSWD: /sbin/ifconfig, /sbin/ifup, /sbin/ifdown, /sbin/ifquery"; \
  } >> /etc/sudoers

  # setup downloads folder as tmpfs
  # that way things are removed on reboot
  # i like things clean but you may not want this
  mkdir -p "/home/$USERNAME/Downloads"
  echo -e "\n# tmpfs for downloads\ntmpfs\t/home/${USERNAME}/Downloads\ttmpfs\tnodev,nosuid,size=2G\t0\t0" >> /etc/fstab
}

# installs docker master
# and adds necessary items to boot params
install_docker() {
  # create docker group
  sudo groupadd docker || true
    sudo gpasswd -a "$USERNAME" docker
    apt-get install -y docker-ce

  systemctl daemon-reload
  systemctl enable docker
}

# install/update golang from source
install_golang() {
  export GO_VERSION=1.7.4
  export GO_SRC=/usr/local/go

  # if we are passing the version
  if [[ ! -z "$1" ]]; then
    export GO_VERSION=$1
  fi

  # purge old src
  if [[ -d "$GO_SRC" ]]; then
    sudo rm -rf "$GO_SRC"
    sudo rm -rf "$GOPATH"
  fi

  # subshell
  (
  curl -sSL "https://storage.googleapis.com/golang/go${GO_VERSION}.linux-amd64.tar.gz" | sudo tar -v -C /usr/local -xz
  local user="$USER"
  # rebuild stdlib for faster builds
  sudo chown -R "${user}" /usr/local/go/pkg
  CGO_ENABLED=0 go install -a -installsuffix cgo std
  )

  # get commandline tools
  (
  set -x
  set +e
  go get github.com/golang/lint/golint
  #go get golang.org/x/tools/cmd/cover
  #go get golang.org/x/review/git-codereview
  #go get golang.org/x/tools/cmd/goimports
  #go get golang.org/x/tools/cmd/gorename
  #go get golang.org/x/tools/cmd/guru

  #go get github.com/jessfraz/apk-file
  #go get github.com/jessfraz/audit
  #go get github.com/jessfraz/bane
  #go get github.com/jessfraz/battery
  #go get github.com/jessfraz/certok
  #go get github.com/jessfraz/cliaoke
  #go get github.com/jessfraz/ghb0t
  #go get github.com/jessfraz/magneto
  #go get github.com/jessfraz/netns
  #go get github.com/jessfraz/netscan
  #go get github.com/jessfraz/onion
  #go get github.com/jessfraz/pastebinit
  #go get github.com/jessfraz/pepper
  #go get github.com/jessfraz/pony
  #go get github.com/jessfraz/reg
  #go get github.com/jessfraz/riddler
  #go get github.com/jessfraz/udict
  #go get github.com/jessfraz/weather

  #go get github.com/axw/gocov/gocov
  #go get github.com/brianredbeard/gpget
  #go get github.com/crosbymichael/gistit
  #go get github.com/crosbymichael/ip-addr
  #go get github.com/davecheney/httpstat
  #go get github.com/google/gops
  #go get github.com/jstemmer/gotags
  #go get github.com/nsf/gocode
  #go get github.com/rogpeppe/godef
  #go get github.com/shurcooL/markdownfmt
  #go get github.com/Soulou/curl-unix-socket

#  aliases=( cloudflare/cfssl docker/docker golang/dep letsencrypt/boulder opencontainers/runc jessfraz/binctr jessfraz/contained.af )
#  for project in "${aliases[@]}"; do
#    owner=$(dirname "$project")
#    repo=$(basename "$project")
#    if [[ -d "${HOME}/${repo}" ]]; then
#      rm -rf "${HOME:?}/${repo}"
#    fi
#
#    mkdir -p "${GOPATH}/src/github.com/${owner}"
#
#    if [[ ! -d "${GOPATH}/src/github.com/${project}" ]]; then
#      (
#      # clone the repo
#      cd "${GOPATH}/src/github.com/${owner}"
#      git clone "https://github.com/${project}.git"
#      # fix the remote path, since our gitconfig will make it git@
#      cd "${GOPATH}/src/github.com/${project}"
#      git remote set-url origin "https://github.com/${project}.git"
#      )
#    else
#      echo "found ${project} already in gopath"
#    fi
#
#    # make sure we create the right git remotes
#    if [[ "$owner" != "jessfraz" ]]; then
#      (
#      cd "${GOPATH}/src/github.com/${project}"
#      git remote set-url --push origin no_push
#      git remote add jessfraz "https://github.com/jessfraz/${repo}.git"
#      )
#    fi
#  done
#
#  # do special things for k8s GOPATH
#  mkdir -p "${GOPATH}/src/k8s.io"
#  kubes_repos=( community kubernetes release test-infra )
#  for krepo in "${kubes_repos[@]}"; do
#    git clone "https://github.com/kubernetes/${krepo}.git" "${GOPATH}/src/k8s.io/${krepo}"
#    cd "${GOPATH}/src/k8s.io/${krepo}"
#    git remote set-url --push origin no_push
#    git remote add jessfraz "https://github.com/jessfraz/${krepo}.git"
#  done
   )
 }

# install graphics drivers
install_graphics() {
  apt-get install -y \
      xorg \
      xserver-xorg
}

# install custom scripts/binaries
install_scripts() {
  # install speedtest
  curl -sSL https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py  > /usr/local/bin/speedtest
  chmod +x /usr/local/bin/speedtest
  echo "Installed speedtest"

  # install icdiff
  curl -sSL https://raw.githubusercontent.com/jeffkaufman/icdiff/master/icdiff > /usr/local/bin/icdiff
  curl -sSL https://raw.githubusercontent.com/jeffkaufman/icdiff/master/git-icdiff > /usr/local/bin/git-icdiff
  chmod +x /usr/local/bin/icdiff
  chmod +x /usr/local/bin/git-icdiff
  echo "Installed icdiff"

  # install lolcat
  curl -sSL https://raw.githubusercontent.com/tehmaze/lolcat/master/lolcat > /usr/local/bin/lolcat
  chmod +x /usr/local/bin/lolcat
  echo "installed lolcat"
}

# install syncthing
install_syncthing() {
  # download syncthing binary
  if [[ ! -f /usr/local/bin/syncthing ]]; then
    curl -sSL https://misc.j3ss.co/binaries/syncthing > /usr/local/bin/syncthing
    chmod +x /usr/local/bin/syncthing
  fi

  syncthing -upgrade

  curl -sSL https://raw.githubusercontent.com/jessfraz/dotfiles/master/etc/systemd/system/syncthing@.service > /etc/systemd/system/syncthing@.service

  systemctl daemon-reload
  systemctl enable "syncthing@${USERNAME}"
}

# install stuff for i3 window manager
install_wmapps() {
  local pkgs=( feh i3 i3lock i3status scrot slim suckless-tools )

  apt-get install -y "${pkgs[@]}"
}

get_dotfiles() {
  # create subshell
  (
  cd "$HOME"

  # install dotfiles from repo
  git clone https://github.com/kyleondy/dotfiles.git "${HOME}/.dotfiles"
  cd "${HOME}/.dotfiles"

  # installs all the things
  make
  chsh -s $(which zsh) ${USERNAME}

  #sudo systemctl enable "i3lock@${USERNAME}"
  #sudo systemctl enable suspend-sedation.service

  #cd "$HOME"
  #mkdir -p ~/Pictures
  #mkdir -p ~/Torrents
  )

  #install_vim;
}

install_vim() {
  # create subshell
  (
  cd "$HOME"

  # update alternatives to neovim
  sudo update-alternatives --install /usr/bin/vi vi "$(which nvim)" 60
  sudo update-alternatives --config vi
  sudo update-alternatives --install /usr/bin/vim vim "$(which nvim)" 60
  sudo update-alternatives --config vim
  sudo update-alternatives --install /usr/bin/editor editor "$(which nvim)" 60
  sudo update-alternatives --config editor
  )
}

install_virtualbox() {
  apt-get update
  apt-get install -y virtualbox-5.1
}

install_vagrant() {
  VAGRANT_VERSION=1.9.1

  # if we are passing the version
  if [[ ! -z "$1" ]]; then
    export VAGRANT_VERSION=$1
  fi

  # check if we need to install virtualbox
  PKG_OK=$(dpkg-query -W --showformat='${Status}\n' virtualbox | grep "install ok installed")
  echo "Checking for virtualbox: $PKG_OK"
  if [ "" == "$PKG_OK" ]; then
    echo "No virtualbox. Installing virtualbox."
    install_virtualbox
  fi

  apt-get update
  apt-get install -y vagrant

  # install plugins
  vagrant plugin install vagrant-vbguest
}


usage() {
  echo -e "install.sh\n\tThis script installs my basic setup for a debian laptop\n"
  echo "Usage:"
  echo "  sources                     (root) - setup sources & install base pkgs"
  echo "  wifi {broadcom,intel}       (user) - install wifi drivers"
  echo "  graphics {dell,mac,lenovo}  (root) - install graphics drivers"
  echo "  wm                          (root) - install window manager/desktop pkgs"
  echo "  dotfiles                    (user) - get dotfiles"
  echo "  vim                         (user) - install vim specific dotfiles"
  echo "  golang                      (user) - install golang and packages"
  echo "  scripts                     (user) - install scripts"
  echo "  syncthing                   (user) - install syncthing"
  echo "  vagrant                     (user) - install vagrant and virtualbox"
}

main() {
  local cmd=$1

  if [[ -z "$cmd" ]]; then
    usage
    exit 1
  fi

  if [[ $cmd == "sources" ]]; then
    check_is_sudo
    setup_sources
    base
  elif [[ $cmd == "graphics" ]]; then
    check_is_sudo
    install_graphics "$2"
  elif [[ $cmd == "wm" ]]; then
    check_is_sudo
    install_wmapps
  elif [[ $cmd == "dotfiles" ]]; then
    get_dotfiles
  elif [[ $cmd == "vim" ]]; then
    install_vim
  elif [[ $cmd == "golang" ]]; then
    install_golang "$2"
  elif [[ $cmd == "scripts" ]]; then
    install_scripts
  elif [[ $cmd == "syncthing" ]]; then
    install_syncthing
  elif [[ $cmd == "vagrant" ]]; then
    install_vagrant "$2"
  else
    usage
  fi
}

main "$@"
