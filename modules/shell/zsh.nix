{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.shell.zsh;
in
{
  options.foundry.shell.zsh = {
    enable = mkEnableOption "zsh stuff";
  };

  config = mkIf cfg.enable {
    programs = {
      zsh = {
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
          f = "foundry";
          cdf = "cd $FOUNDRY_DATA";
          cdtmp = "cd $(mktemp -d)";
          lsd = "ls -l $@ | grep '^d'";
          llr = "ll --color=auto -t | head";
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

          # nicer autocomplete selections
          zstyle ':completion:*' menu select # use arrows to navigate autocomplete results
          zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}' # lowers match uppers
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
            fzf "$@" --multi --ansi --border
          }
          fzf_pick_git_commit() {
            is_in_git_repo || return
            # I've already put a lot of time into my `git lg` alias an am very
            # familiar with how it looks. I am just reusing most of the logic here.
            # I force `--color` becuase git will output this without color by
            # default.
            git log --color --pretty=format:'%Cred%h%Creset -%G?-%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' |
            _fzf --no-sort --reverse \
              --preview 'grep -o "[a-f0-9]\{7,\}" <<< {} | xargs git show --color=always | head -'$LINES |
            grep -o "[a-f0-9]\{7,\}"
          }
          fzf_pick_git_tag() {
            is_in_git_repo || return
            git tag --sort -version:refname |
            _fzf --preview-window right:70% \
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
            _fzf  --tac --preview-window right:70% \
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
            aws_profile=$(grep '\[profile .*\]' "$HOME/.aws/config" | cut -d' ' -f2 | rev | cut -c 2- | rev | _fzf)
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

          # https://book.babashka.org/#_terminal_tab_completion
          _bb_tasks() {
            local matches=(`bb tasks |tail -n +3 |cut -f1 -d ' '`)
            compadd -a matches
            _files # autocomplete filenames as well
          }
          compdef _bb_tasks bb

          # spaceship config
          # todo: not sure this is the best way to instll the theme
          mkdir -p "$HOME/.zfunctions"
          fpath=( "$HOME/.zfunctions" $fpath )
          ln -sf "${pkgs.spaceship-prompt}/lib/spaceship-prompt/spaceship.zsh" "$HOME/.zfunctions/prompt_spaceship_setup"
          autoload -U promptinit; promptinit
          prompt spaceship
          eval spaceship_vi_mode_enable # https://github.com/denysdovhan/spaceship-prompt/issues/799
          # Here are some symbols I'd love to use somewhere
          #  U+2615   HOT BEVERAGE          ☕
          #  U+2620   SKULL AND CROSSBONES  ☠
          #  U+2622   RADIOACTIVE SIGN      ☢
          export SPACESHIP_CHAR_SYMBOL='λ '
          export SPACESHIP_CHAR_SYMBOL_ROOT='☢ '
          export SPACESHIP_TIME_SHOW=true
          export SPACESHIP_KUBECTL_SHOW=true
          export SPACESHIP_KUBECTL_VERSION_SHOW=false # don't care what version
          export SPACESHIP_KUBECONTEXT_COLOR_GROUPS=(
            # red if namespace is "kube-system"
            green  dev
            yellow staging
            red    prod
          )
        '' +

        # The double single quote `''` is to escape the `${` character
        # combination that nix wants to replace with a variable. Its not some
        # fancy bash trick. In the bash source, the double quotes does not
        # appear.
        ''
          # PS$ is used when command printing (`set -x`) it turned on. The will
          # print the scripts, function, and line number.
          #
          # see `man bash` for available expansions
          # https://news.ycombinator.com/item?id=27617128
          #
          export PS4='+ ''${BASH_SOURCE:-}:''${FUNCNAME[0]:-}:L${LINENO:-}:   '
        '';
      };
      fzf = {
        enable = true;
        enableZshIntegration = true;
      };
    };
    home.packages = with pkgs;
      [
        spaceship-prompt # promt for zsh
      ];
  };
}
