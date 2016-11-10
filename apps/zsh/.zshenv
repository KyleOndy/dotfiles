#Since .zshenv is always sourced, it often contains exported variables that should be available to other programs. For example, $PATH, $EDITOR, and $PAGER are often set in .zshenv. Also, you can set $ZDOTDIR in .zshenv to specify an alternative location for the rest of your zsh configuration.

# .zshenv → [.zprofile if login] → [.zshrc if interactive] → [.zlogin if login] → [.zlogout sometimes].

ZDOTDIR=$HOME/.config/zsh
DOTFILES=$HOME/.dotfiles

if [ "$XDG_CURRENT_DESKTOP" = "i3" ]; then
  # i3-sensible-terminal needs this set to use a 256 color term
  export TERMINAL="urxvt256c"
fi
#
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

# Colorful man pages
# from http://pastie.org/pastes/206041/text
#export LESS_TERMCAP_mb="(set_color -o red)"
#export LESS_TERMCAP_md="(set_color -o red)"
#export LESS_TERMCAP_me="(set_color normal)"
#export LESS_TERMCAP_se="(set_color normal)"
#export LESS_TERMCAP_so="(set_color -b blue -o yellow)"
#export LESS_TERMCAP_ue="(set_color normal)"
#export LESS_TERMCAP_us="(set_color -o green)"

# No asnible cows
export ANSIBLE_NOCOWS=1

# Golang config
export GOPATH="$HOME/go"

export DOTFILES="$HOME/.dotfiles"
export MAIL_BACKUP="$HOME/Dropbox/.mail"
