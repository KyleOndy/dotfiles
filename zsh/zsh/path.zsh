typeset -U path

path=(~/.cabal/bin "$path[@]")
path=(~/.rbenv/bin "$path[@]")

# prune paths that don't exist
path=($^path(N))
