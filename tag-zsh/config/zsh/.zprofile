# using TMUX and ZSH have some weird interactions.
# I've set tmux to open a new zsh shell (sourcing .zshrc)
# so any path setting needs to be sone here to prevent
# duplicates

export XDG_CACHE_HOME="$HOME/.cache"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"

export GNUPGHOME="$XDG_CONFIG_HOME/gnupg"
export GOPATH="$XDG_CONFIG_HOME/go"
export LESSHISTFILE="$XDG_CACHE_HOME/lesshist"
export NOTMUCH_CONFIG="$XDG_CONFIG_HOME/notmuchrc"
export RCRC="$XDG_CONFIG_HOME/rcrc"


# local bins
export PATH="$HOME/.local/bin:$PATH"

# stack bins
export PATH="$HOME/.stack/bin:$PATH"
#
# gem path
#export PATH="$HOME/.gem/ruby:$PATH"

# userd for i3
export TERMINAL="urxvt"
