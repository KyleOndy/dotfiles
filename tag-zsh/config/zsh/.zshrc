# .zshrc is for interactive shell configuration. You set options for the interactive shell there with the  setopt and unsetopt commands. You can also load shell modules, set your history options, change your prompt, set up zle and completion, et cetera. You also set any variables that are only used in the interactive shell (e.g. $LS_COLORS).


# proxy setup. Sometimes you just have to deal with things
# check if a system wide proxy as been set
# todo: this only handles work things. need to make more robust
# todo: /etc seems like the wrong place for this.
if [[ -a /etc/proxy ]]
then
  PROXY="$(cat /etc/proxy)"
  export http_proxy=$PROXY
  export https_proxy=$PROXY
  export no_proxy=localhost,127.0.0.1,169.254.169.254
else
  # if these are not explicilty unset the proxy vars will propogate to child
  # shells sinec the `update-proxy` script does not remove them.
  unset http_proxy
  unset https_proxy
  unset no_proxy
fi

if [ -z "$NO_MESSAGE" ]; then
  message_dir="/tmp/messages"

  message=$(fortune -e debian debian-hints linux)
  # if the directory existis, and there is at least one file there
  if [ -d "$message_dir" ] && [ "$(ls -A $message_dir)" ]; then
    # set the message to the status message
    message=$(cat "$message_dir/$(ls -1 $message_dir | sort -hr | head -n1)")
  fi

  cowsay "$message"
fi

# Load plugins
source $ZDOTDIR/antigen/antigen.zsh
antigen use oh-my-zsh
antigen bundles <<EOBUNDLES
  colored-man-pages
  docker
  gitfast
  gpg-agent
  npm
  pass
  pip
  rbenv
  ssh-agent
  sudo
  vagrant
  zsh-users/zsh-autosuggestions
  zsh-users/zsh-history-substring-search
  zsh-users/zsh-syntax-highlighting
EOBUNDLES
antigen theme daveverwer
antigen apply

[[ -f "$HOME/.fzf.zsh" ]] && source "$HOME/.fzf.zsh"

alias :q='exit'
alias :e='nvim'
alias :E='nvim .'
function lsd() { ls -l $@ | grep "^d" }

alias tree='tree --dirsfirst -ChFQ'
function tree1() { tree -L 1 $@ }
function tree2() { tree -L 2 $@ }
function tree3() { tree -L 3 $@ }
function tree4() { tree -L 4 $@ }
function tree5() { tree -L 5 $@ }
function tree6() { tree -L 6 $@ }

#use the 'tree' alias we defined above
alias treea="tree -a -I '.git|.stack-work'"
function treea1() { treea -L 1 $@ }
function treea2() { treea -L 2 $@ }
function treea3() { treea -L 3 $@ }
function treea4() { treea -L 4 $@ }
function treea5() { treea -L 5 $@ }
function treea6() { treea -L 6 $@ }

function bigdirs() { du -h --max-depth=1 $@ | sort -h }
functions filecount() { du -a | cut -d/ -f2 | sort | uniq -c | sort -n }

alias ghc='stack exec -- ghc'
alias ghci='stack exec -- ghci'

alias gpg=gpg2

alias xc=xclip selection -primary $@
alias t="$EDITOR ${XDG_DATA_HOME}/todo/todo.md"

alias sum='paste -sd+ - | bc'

alias v="amixer -q set Master $@ unmute"
alias vu='amixer -q set Master 3+ unmute'
alias vd='amixer -q set Master 3- unmute'
alias vm='amixer -q set Master toggle'
alias did="nvim +'normal Go' +'r!date' +'normal o' ~/did.txt"
alias tar_backup='tarsnapper -c ~/.config/tarsnap/tarsnap.conf make'

# docker commands
# todo: move these to a seperate file to keep things tidy
alias http_server='docker run --rm -it -v $(pwd):/var/www:ro -w /var/www -p 8000:8000 python:3-alpine python -m http.server'
function function inspec { docker run -it --rm -e http_proxy=$PROXY -e http_proxy=$PROXY -v $(pwd):/share chef/inspec "$@"; }

# Bells
unsetopt beep                   # no bell on error
unsetopt hist_beep              # no bell on error in history
unsetopt list_beep              # no bell on ambiguous completion
if [ -n "$DISPLAY" ]; then
  xset b off
fi

# look into history options
setopt inc_append_history
setopt share_history

# let shellcheck follow files
export SHELLCHECK_OPTS='-x'

# let fzf use a tmux pane
export FZF_TMUX=1

# pyenv setup
if command -v pyenv 1>/dev/null 2>&1; then
  eval "$(pyenv init -)"
  eval "$(pyenv virtualenv-init -)"
fi

# pipenv
if command -v pipenv 1>/dev/null 2>&1; then
  eval "$(pipenv --completion)"
fi

[[ -f "$HOME/.src/z/z.sh" ]] && source "$HOME/.src/z/z.sh"

source "$HOME/.sdkman/bin/sdkman-init.sh"

[[ -f "$ZDOTDIR/.zshrc.local" ]] && source "$ZDOTDIR/.zshrc.local"
