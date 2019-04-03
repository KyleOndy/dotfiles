These are my personal dot files.
Feel free to use anything for inspiration or verbatim.
I know I have used _plenty_ of other people's dotfiles for inspiration.

I have tried to keep each configuration file well documented to avoid duplicating any documentation here.

## Setup

These dotfiles are managed with [rcm], a simple dotfile management tool built by [ThoughtBot].

Other applications I assume that are installed:

- cowsay
- dnsutils
- git
- zsh

## Initial Setup

The first run the `RCRC` variable needs to be set as I use a nonstandard install location for `rcm` (defaults to `~/.rcrc`).

```bash
git clone https://github.com/kyleondy/dotfiles.git "$HOME/.dotfiles"
RCRC=$HOME/.dotfiles/config/rcrc rcup -v
```

The [post-up] script takes care of downloading or updating some external dependencies.

## Updating

To update the entire system: `update-system --help`.
If only updating the dotfiles: `rcup`.

[rcm]: https://github.com/thoughtbot/rcm
[ThoughtBot]: https://github.com/thoughtbot
[post-up]: ./hooks/post-up
