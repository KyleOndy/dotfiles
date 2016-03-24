This is the public branch for my personal dot files.
Feel free to use anything for inspiration or verbatim.

Many of my dotfiles are either heavily inspired by other people or outright copied.

how to check for missing programs I frequently use.

    ./check.sh | grep missing

## File Structure

For ease of maitnecne each application is split into its own directory.
The file strucutre of each unser the root app is realative to $HOME.
Each file is symlinked indivudally, so a folder can contain files from multipule apps.
Due to this hoever, folders themself are not symlinked. This is a bit hacky right now.
