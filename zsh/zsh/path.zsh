typeset -U path

path=(~/.cabal/bin "$path[@]")
path=(~/.rbenv/bin "$path[@]")
path=(~/.gem/ruby/2.2.0/bin "$path[@]")
path=(~/.local/bin "$path[@]")

# prune paths that don't exist
path=($^path(N))
