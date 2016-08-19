# Language settings
set -x LC_ALL en_US.UTF-8
set -x LC_CTYPE en_US.UTF-8

# respect local bins
set -x PATH "./bin" $PATH

# my own little utils
set -x PATH "$HOME/bin" $PATH

# stack bins
set -x PATH "$HOME/.local/bin" $PATH

# gem path
set -x PATH "$HOME/.gem/ruby" $PATH

# editor
set -x EDITOR "nvim"

# i3-sensible-terminal needs this set to use a 256 color term
set -x TERMINAL "urxvt256c"

# LESS with colors
# from http://blog.0x1fff.com/2009/11/linux-tip-color-enabled-pager-less.html
set -x PAGER "less"
set -x LESS "-RSM~gIsw"

if test -e /usr/bin/src-hilite-lesspipe.sh
  set -x LESSOPEN "| /usr/bin/src-hilite-lesspipe.sh %s"
end

# Colorful man pages
# from http://pastie.org/pastes/206041/text
setenv -x LESS_TERMCAP_mb (set_color -o red)
setenv -x LESS_TERMCAP_md (set_color -o red)
setenv -x LESS_TERMCAP_me (set_color normal)
setenv -x LESS_TERMCAP_se (set_color normal)
setenv -x LESS_TERMCAP_so (set_color -b blue -o yellow)
setenv -x LESS_TERMCAP_ue (set_color normal)
setenv -x LESS_TERMCAP_us (set_color -o green)

# No asnible cows
set -x ANSIBLE_NOCOWS 1

# Golang config
set -x GOPATH "$HOME/go"

# Diable fish greeting
set -x fish_greeting

set -x DOTFILES "$HOME/.dotfiles"
