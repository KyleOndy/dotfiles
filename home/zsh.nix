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
    initExtra = ''
      include () {
        [[ -f "$1" ]] && source "$1"
      }

      # shell hooks
      eval "$(direnv hook zsh)"

      # zsh tweaks not included in home-manager.
      # todo: add these to home-manager and contribute upsteam

      # reduce <ESC> key timeout in vim mode
      export KEYTIMEOUT=50

      # change the auto-completion color
      # todo: there is probably a better way
      export ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=6'

      # my quality of life functions

      # less keystrokes for common actions
      f() {
        if [[ -z "$1" ]]; then
          ls
        elif [[ -f "$1" ]]; then
          $EDITOR "$1"
        elif [[ -d "$1" ]]; then
          cd "$1" || exit 1
          ls
        fi
      }


      # todo: not sure this is the best way to instll the theme
      mkdir -p "$HOME/.zfunctions"
      fpath=( "$HOME/.zfunctions" $fpath )
      ln -sf "${pkgs.spaceship-prompt}/lib/spaceship-prompt/spaceship.zsh" "$HOME/.zfunctions/prompt_spaceship_setup"
      autoload -U promptinit; promptinit
      prompt spaceship
      export SPACESHIP_TIME_SHOW=true # show timestamps in prompt
      eval spaceship_vi_mode_enable # https://github.com/denysdovhan/spaceship-prompt/issues/799

      # nicer autocomplete selections
      zstyle ':completion:*' menu select # use arrows to navigate autocomplete results

      # easily cycle through history with up and down arrow
      bindkey "^[[A" history-beginning-search-backward
      bindkey "^[[B" history-beginning-search-forward

      # I really want the vi binding to more vim like
      bindkey -v '^?' backward-delete-char # allow backspace key to work as expected

      # open the commnad line in $EDITOR
      autoload -z edit-command-line
      zle -N edit-command-line
      bindkey -M vicmd v edit-command-line

      # match my binding for [neo]vim
      bindkey -M viins 'jk' vi-cmd-mode

      setopt ignoreeof # don't close my shell on ^d. Why is that a good idea?

      # this is bound to '\ec' (alt-c) by defaul, but I really like having this
      # shortcut available on a control key combo
      bindkey '^e' fzf-cd-widget

      # fancy git + fzf
      # todo: refactor this into its own script and just source it
      is_in_git_repo() {
        git rev-parse HEAD > /dev/null 2>&1
      }

      _fzf() {
        fzf "$@" --border
      }

      fzf_pick_git_commit() {
        is_in_git_repo || return
        # I've already put a lot of time into my `git lg` alias an am very
        # familiar with how it looks. I am just reusing most of the logic here.
        # I force `--color` becuase git will output this without color by
        # default.
        git log --color --pretty=format:'%Cred%h%Creset -%G?-%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' |
        _fzf --ansi --no-sort --reverse --multi \
          --preview 'grep -o "[a-f0-9]\{7,\}" <<< {} | xargs git show --color=always | head -'$LINES |
        grep -o "[a-f0-9]\{7,\}"
      }

      fzf_pick_git_tag() {
        is_in_git_repo || return
        git tag --sort -version:refname |
        _fzf --multi --preview-window right:70% \
          --preview 'git show --color=always {} | head -'$LINES
      }

      fzf_pick_git_remote() {
        is_in_git_repo || return
        git remote -v | awk '{print $1 "\t" $2}' | uniq |
        _fzf --tac \
          --preview 'git log --oneline --graph --date=short --pretty="format:%C(auto)%cd %h%d %s" {1} | head -200' |
        cut -d$'\t' -f1
      }

      fzf_pick_git_branch() {
        is_in_git_repo || return
        git branch -a --color=always | grep -v '/HEAD\s' | sort |
        _fzf --ansi --multi --tac --preview-window right:70% \
          --preview 'git log --oneline --graph --date=short --color=always --pretty="format:%C(auto)%cd %h%d %s" $(sed s/^..// <<< {} | cut -d" " -f1) | head -'$LINES |
        sed 's/^..//' | cut -d' ' -f1 |
        sed 's#^remotes/##'
      }

      # A helper function to join multi-line output from fzf
      join-lines() {
        local item
        while read item; do
          echo -n "''${(q)item} "
        done
      }

      fzf-git-commit-widget() {
          LBUFFER+=$(fzf_pick_git_commit | join-lines)
      }
      zle -N fzf-git-commit-widget
      bindkey '^g^g' fzf-git-commit-widget

      fzf-git-tag-widget() {
          LBUFFER+=$(fzf_pick_git_tag | join-lines)
      }
      zle -N fzf-git-tag-widget
      bindkey '^g^t' fzf-git-tag-widget

      fzf-git-remote-widget() {
          LBUFFER+=$(fzf_pick_git_remote | join-lines)
      }
      zle -N fzf-git-remote-widget
      bindkey '^g^r' fzf-git-remote-widget

      fzf-git-branch-widget() {
          LBUFFER+=$(fzf_pick_git_branch | join-lines)
      }
      zle -N fzf-git-branch-widget
      bindkey '^g^b' fzf-git-branch-widget

      fzf_pick_aws_profile() {
        aws_profile=$(grep '[.*]' "$HOME/.aws/credentials" | cut -c 2- | rev | cut -c 2- | rev | _fzf)
        export AWS_PROFILE="$aws_profile"
      }
      zle -N fzf_pick_aws_profile
      bindkey '^a^p' fzf_pick_aws_profile

      # easily export which kube config I want. I can't break things if I can
      # not connect to the cluster.
      fzf_pick_kube_config() {
        config_dir="$HOME/.kube/configs"
        # becuase at $WORK I use darwin, I don't have GNU find, and need to do
        # these shenanigans with `basename`.
        kubeconfig=$(find "$config_dir" -type f -exec basename {} \; | sort |
        _fzf --preview "bat --color=always "$config_dir/{}"")
        export KUBECONFIG="$config_dir/$kubeconfig"
      }
      zle -N fzf_pick_kube_config
      bindkey '^k^k' fzf_pick_kube_config
    '';
  };
  home.packages = with pkgs;
    [
      spaceship-prompt # promt for zsh
    ];
}
