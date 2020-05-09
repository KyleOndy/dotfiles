# This file contains all the configuration for ZSH specifically, and not more
# general shell configuration.
{ pkgs, ... }:

{

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    enableAutosuggestions = true;
    autocd = false; # I can't stand when ZSH Decided to change my directory
    defaultKeymap = "viins";
    history = {
      extended = true; # save timestamps
      ignoreDups = false; # log all commands
      save = 10000; # lots of history. Internal history list
      size = 100000; # lots of history. Save to file.
      share = true; # let multiple ZSH session write to the history file
    };
    shellAliases = {
      ":e" = "$EDITOR";
      ":q" = "exit";
      cdtmp = "cd $(mktemp -d)";
      l = "ls";
      lsd = "ls -l $@ | grep '^d'";
      r = "ranger";
      src = "cd $HOME/src";
      tree = "tree --dirsfirst -ChFQ $@";
      tree1 = "tree -L 1 $@";
      tree2 = "tree -L 2 $@";
      tree3 = "tree -L 3 $@";
    };
    oh-my-zsh = {
      enable = true;
      plugins = [
        "colored-man-pages"
        "docker"
        "gitfast"
        "pass"
        "pip"
        "rbenv"
        "ssh-agent"
        "sudo"
      ];
      theme = "juanghurtado";
    };
    initExtra = ''
      include () {
        [[ -f "$1" ]] && source "$1"
      }

      # shell hooks
      eval "$(direnv hook zsh)"

      # my quality of life functions
      fzf_pick_git_commit() {
        # I've already put a lot of time into my `git lg` alias an am very
        # familiar with how it looks. I am just reusing most of the logic here.
        # I force `--color` becuase git will output this without color by
        # default.
        LOG_LINE=$(git log --color --pretty=format:'%Cred%h%Creset -%G?-%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' | fzf --ansi)
        # as the git commit ref is the first item in the line, split at the
        # first space and take the first argument.
        echo -n "$LOG_LINE" | cut -d' ' -f1 | tr -d $'\n'
      }

      # now <ctrl> + y gives me a nice popup to select a git commit hash from a
      # nicely formatted list
      _zle_pick_git_commit() {
        COMMIT=$(fzf_pick_git_commit)
        LBUFFER=$LBUFFER$COMMIT
      }
      zle -N _zle_pick_git_commit
      bindkey '^y' _zle_pick_git_commit
    '';
  };
}
