# .zshrc is for interactive shell configuration. You set options for the interactive shell there with the  setopt and unsetopt commands. You can also load shell modules, set your history options, change your prompt, set up zle and completion, et cetera. You also set any variables that are only used in the interactive shell (e.g. $LS_COLORS).


# is the internet on fire status reports
host -t txt istheinternetonfire.com | cut -f 2 -d '"' | cowsay -f moose

# Load plugins
source $ZDOTDIR/antigen/antigen.zsh
antigen use oh-my-zsh
antigen bundles <<EOBUNDLES
  zsh-users/zsh-syntax-highlighting
  zsh-users/zsh-autosuggestions
  zsh-users/zsh-history-substring-search
  colored-man-pages
  pass
  docker
  gpg-agent
  gitfast
  npm
  pip
  sudo
EOBUNDLES
antigen theme daveverwer
antigen apply

[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
[[ -f ~/.fzf.zsh ]] && source ~/.fzf.zsh

# alias. Move to different file?
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

alias gst='git status'

# look into history options
setopt inc_append_history
setopt share_history
