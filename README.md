These are my personal dot files.
Feel free to use anything for inspiration or verbatim.
I know I have used plenty of other people's dotfiles for inspiration.

## Setup

Need [rcm](https://github.com/thoughtbot/rcm), a simple dotfile management tool built by [ThoughtBot](https://github.com/thoughtbot)

Other applications I assume that are installed:

- zsh
- cowsay
- dnsutils
- git

## Initial Setup

On initial running, needs to set the `RCRC` variable as I use a nonstandard install location for `rcm` (defaults to `~/.rcrc`).

```bash
git clone https://github.com/kyleondy/dotfiles.git "$HOME/.dotfiles"
RCRC=$HOME/.dotfiles/config/rcrc rcup -v
```

## Updating

To update the entire system: `update-system`.
If only updating the dotfiles: `rcup`.
