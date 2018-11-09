# .zshrc is for interactive shell configuration. You set options for the interactive shell there with the  setopt and unsetopt commands. You can also load shell modules, set your history options, change your prompt, set up zle and completion, et cetera. You also set any variables that are only used in the interactive shell (e.g. $LS_COLORS).


# is the internet on fire status reports, if we have network
mkdir -p /tmp/messages

# grab message every halfhour
MESSAGE_FILE=/tmp/messages/$(echo "$(date "+%Y%m%d%H%M") - ($(date +%M)%30)" | bc)

if [[ ! -a "$MESSAGE_FILE" ]]; then
  # need to get a new message
  MESSAGE=$(host -W1 -t txt istheinternetonfire.com | cut -f 2 -d '"') || "Could not get txt record of istheinternetonfire.com"
  echo $MESSAGE > "$MESSAGE_FILE"
fi
cowsay < $MESSAGE_FILE

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

alias t='tree'
alias ta='treea'

function bigdirs() { du -h --max-depth=1 $@ | sort -h }
functions filecount() { du -a | cut -d/ -f2 | sort | uniq -c | sort -n }

alias ghc='stack exec -- ghc'
alias ghci='stack exec -- ghci'

alias gpg=gpg2

alias gst='git status'

alias xc=xclip selection -primary $@

alias sum='paste -sd+ - | bc'

alias v="amixer -q set Master $@ unmute"
alias vu='amixer -q set Master 3+ unmute'
alias vd='amixer -q set Master 3- unmute'
alias vm='amixer -q set Master toggle'

alias http_server='docker run --rm -it -v $(pwd):/var/www:ro -w /var/www -p 8000:8000 python:3-alpine python -m http.server'
alias tar_backup='tarsnapper -c ~/.config/tarsnap/tarsnap.conf make'

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

# Set python version via pyenv
export PYENV_VERSION=3.7.1

# pyenv setup
if command -v pyenv 1>/dev/null 2>&1; then
  eval "$(pyenv init -)"
  eval "$(pyenv virtualenv-init -)"
fi

[[ -f "$ZDOTDIR/.zshrc.local" ]] && source "$ZDOTDIR/.zshrc.local"
