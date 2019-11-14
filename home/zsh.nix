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
      extended = true;    # save timestamps
      ignoreDups = false; # log all commands
      save = 10000;       # lots of history. Internal history list
      size = 100000;      # lots of history. Save to file.
      share = true;       # let multiple ZSH session write to the history file
    };
    shellAliases = {
      ":q" = "exit";
      ":e" = "$EDITOR";
      l = "ls";
      lsd = "ls -l $@ | grep '^d'";
      tree = "tree --dirsfirst -ChFQ $@";
      tree1 = "tree -L 1 $@";
      tree2 = "tree -L 2 $@";
      tree3 = "tree -L 3 $@";
      r = "ranger";
    };
    oh-my-zsh = {
      enable = true;
      plugins = [
        "colored-man-pages"
        "docker"
        "gitfast"
        "gpg-agent"
        "pass"
        "pip"
        "rbenv"
        "ssh-agent"
        "sudo"
      ];
      theme = "dieter";
    };
  };
}