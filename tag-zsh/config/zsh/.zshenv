#Since .zshenv is always sourced, it often contains exported variables that should be available to other programs. For example, $PATH, $EDITOR, and $PAGER are often set in .zshenv. Also, you can set $ZDOTDIR in .zshenv to specify an alternative location for the rest of your zsh configuration.

# .zshenv → [.zprofile if login] → [.zshrc if interactive] → [.zlogin if login] → [.zlogout sometimes].

ZDOTDIR=$HOME/.config/zsh
DOTFILES=$HOME/.dotfiles

#if [ "$XDG_CURRENT_DESKTOP" = "i3" ]; then
#  # i3-sensible-terminal needs this set to use a 256 color term
#  export TERMINAL="urxvt"
#fi

## editor
export VISUAL='nvim'
export EDITOR=$VISUAL

# Reduce to 0.1 secs the delay after hitting the <ESC> key.
export KEYTIMEOUT=1

## Language settings
export LC_ALL=en_US.UTF-8
export LC_CTYPE=en_US.UTF-8

# LESS with colors
# from http://blog.0x1fff.com/2009/11/linux-tip-color-enabled-pager-less.html
export PAGER="less"
export LESS="-RSM~gIsw"

if [ -f /usr/bin/src-hilite-lesspipe.sh ]; then
  export LESSOPEN="| /usr/bin/src-hilite-lesspipe.sh %s"
fi;

# No asnible cows
export ANSIBLE_NOCOWS=1

# Golang config
export GOPATH="$HOME/go"

export DOTFILES="$HOME/.dotfiles"
export MAIL_BACKUP="$HOME/Dropbox/.mail"

# XDG
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"

export GNUPGHOME="$XDG_CONFIG_HOME/gnupg"
export GOPATH="$XDG_CONFIG_HOME/go"
export LESSHISTFILE="$XDG_CACHE_HOME/lesshist"
export NOTMUCH_CONFIG="$XDG_CONFIG_HOME/notmuchrc"
export RCRC="$XDG_CONFIG_HOME/rcrc"


# userd for i3
export TERMINAL="urxvt"

# path
typeset -U path
path=(
  $HOME/.stack/bin
  $HOME/.local/bin
  $GOPATH/bin
  $HOME/.rbenv/bin
  $path
)
