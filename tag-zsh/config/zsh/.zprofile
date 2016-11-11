# using TMUX and ZSH have some weird interactions.
# I've set tmux to open a new zsh shell (sourcing .zshrc)
# so any path setting needs to be sone here to prevent
# duplicates

# local bins
export PATH="$HOME/.local/bin:$PATH"
#
# gem path
export PATH="$HOME/.gem/ruby:$PATH"

# Finally, start x
if [ -z "$DISPLAY" ] && [ -n "XDG_VTNR" ] && [ $XDG_VTNR -eq 1 ]; then
  exec startx
fi
