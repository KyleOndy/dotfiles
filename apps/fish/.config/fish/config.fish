set -x PATH ~/.local/bin $PATH

alias vim nvim
alias vi nvim

alias ghc 'stack exec -- ghc'
alias ghci 'stack exec -- ghci'

alias treea 'tree -a -I .git'

# source local config
. ~/.config/fish/config.fish.local
