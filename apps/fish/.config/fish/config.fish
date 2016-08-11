# Check if we have the most up to date copy of dotfiles
checkDotsUpdate

. "$HOME/.config/fish/functions/export.fish"
. "$HOME/.config/fish/functions/aliases.fish"
. "$HOME/.config/fish/functions/utils.fish"

# source local config
. "$HOME/.config/fish/config.fish.local"
