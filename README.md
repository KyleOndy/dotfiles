# Kyle's Dots

These are the dotfiles I use both for personal and the majority of my professional work.
Feel free to use anything for inspiration or verbatim.
I know I have used _plenty_ of other people's dotfiles for inspiration through out the years.
Going forward I am trying to at minimum leave a note of attribution in a comment when the configuration is taken from somewhere other than a manpage.

To avoid redundant documentation, I strive to keep each configuration file well commented to negate the need for additional documentation.
Some subfolders to have a `README` to further expand on topics not included within the configuration itself.

## Setup

These dotfiles are managed with [rcm], a simple dotfile management tool built by [ThoughtBot].

These dotfiles are assumed to be applied in an environment with the following applications available.

- cowsay
- dnsutils
- git
- zsh

### Initial Setup

On the first run of `rcm`, the `RCRC` variable needs to be set as I use a nonstandard install location for `rcm` (defaults to `~/.rcrc`).

```bash
git clone https://github.com/kyleondy/dotfiles.git "$HOME/.dotfiles"
RCRC=$HOME/.dotfiles/config/rcrc rcup -v
```

The [post-up] script takes care of downloading or updating some external dependencies.

### Updating

To update the entire system: `update-system --help`.
If only updating the dotfiles: `rcup`.

[rcm]: https://github.com/thoughtbot/rcm
[ThoughtBot]: https://github.com/thoughtbot
[post-up]: ./hooks/post-up
