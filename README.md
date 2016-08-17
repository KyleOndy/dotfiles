These are my personal dot files.
Feel free to use anything for inspiration or verbatim.
I know I've used plenty of people for inspiration.


## File Structure

~~~.bash
~/apps/Organizational_Dir/Path_Relative_To_$HOME
~~~

Each set of logically grouped dotfiles gets it's own directory Within the `apps` directory.
These top level directories (Organizational_Dir) have no impact to the location of the dotfiles, they are purely for organization purposes.

The next level (Path_Relative_To_$HOME) get symlinked into $HOME.

e.x.

~~~.bash
# vimrc
app/vim/.vim/vimrc -> ~/.vim/vimrc
~~~

Each file is symlinked indivudally, so a folder can contain files from multipule apps.
Due to this hoever, folders themself are not symlinked. This is a bit hacky right now.

## Dots for the following Applications

### X11
Everyone favorite windowing system

### [fish](https://fishshell.com/)

fish is a smart and user-friendly command line shell for OS X, Linux, and the rest of the family.

### [git](https://git-scm.com/)
version control everything

### [gnupg2](www.gnupg.org/)

Everyone should take the time to learn how PGP works and use it

### misc-utils

Small scripts and such that don't deserve their own repo

### [msmtp](msmtp.sourceforge.net)

Lightweight smtp client

### [mutt](www.mutt.org)

I actually use [neomutt](http://www.neomutt.org/) which has all the community patches built it.

### [neovim](https://neovim.io/)

Fork of the best text editor ever, [vim](http://www.vim.org/)

### [notmuch](https://notmuchmail.org/)
email indexer

### [offlineimap](http://www.offlineimap.org/)
IMAP -> Maildir

### [stack](https://docs.haskellstack.org/en/stable/README/)
Haskell tooling

### [tmux](https://tmux.github.io/)
Terminal multiplexer

### [vim](www.vim.org)

My old config files I can't get rid of

### weechat
My irc client of choice

## TODO

[ ] mutt colorscheme needs some love and tweaking
