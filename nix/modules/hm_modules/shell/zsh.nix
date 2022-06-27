{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.shell.zsh;
in
{
  options.hmFoundry.shell.zsh = {
    enable = mkEnableOption "zsh stuff";
  };

  config = mkIf cfg.enable {
    programs = {
      zsh = {
        enable = true;
        enableCompletion = true;
        enableAutosuggestions = true;
        autocd = false; # I can't stand when ZSH Decided to change my directory
        history = {
          extended = true; # save timestamps
          ignoreDups = true;
          save = 1000000; # lots of history. Internal history list
          size = 1000000; # lots of history. Save to file.
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
        # The double single quote `''` is to escape the `${` character
        # combination that nix wants to replace with a variable. Its not some
        # fancy bash trick. In the bash source, the double quotes do not
        # appear.
        initExtra = ''
          # do this early, so I can overwrite settings as I want.
          source ${pkgs.zsh-vi-mode}/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh
          # Only changing the escape key to `jk` in insert mode, we still
          # keep using the default keybindings `^[` in other modes
          ZVM_VI_INSERT_ESCAPE_BINDKEY=jk
          # I never _intend_ or _expect_ to start in normal mode and it throws
          # me off every time.
          ZVM_LINE_INIT_MODE=$ZVM_MODE_INSERT

          zvm_after_init() {
            # White ZVM is super nifty, and better than the built in vi mode,
            # it does clobber some key bindings; here we source FZF to get
            # those bindings back.
            #
            # https://github.com/jeffreytse/zsh-vi-mode/issues/24
            source "${pkgs.fzf}/share/fzf/key-bindings.zsh"
            source "${pkgs.fzf}/share/fzf/completion.zsh"
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
          # I really want the vi binding to more vim like
          # bindkey -v '^?' backward-delete-char # allow backspace key to work as expected
          # open the commnad line in $EDITOR
          #autoload -z edit-command-line
          #zle -N edit-command-line
          #bindkey -M vicmd v edit-command-line
          # match my binding for [neo]vim
          #bindkey -M viins 'jk' vi-cmd-mode
          setopt ignoreeof # don't close my shell on ^d. Why is that a good idea?
          # fancy git + fzf
          # todo: refactor this into its own script and just source it
          is_in_git_repo() {
            ${pkgs.git}/bin/git rev-parse HEAD > /dev/null 2>&1
          }
          _fzf() {
            ${pkgs.fzf}/bin/fzf "$@" --multi --ansi --border
          }
          fzf_pick_git_commit() {
            is_in_git_repo || return
            # I've already put a lot of time into my `git lg` alias an am very
            # familiar with how it looks. I am just reusing most of the logic here.
            # I force `--color` becuase git will output this without color by
            # default.
            ${pkgs.git}/bin/git log --color --pretty=format:'%Cred%h%Creset -%G?-%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' |
            _fzf --no-sort --reverse \
              --preview '${pkgs.gnugrep}/bin/grep -o "[a-f0-9]\{7,\}" <<< {} | ${pkgs.findutils}/bin/xargs ${pkgs.git}/bin/git show --color=always | head -'$LINES |
            grep -o "[a-f0-9]\{7,\}"
          }
          fzf_pick_git_tag() {
            is_in_git_repo || return
            ${pkgs.git}/bin/git tag --sort -version:refname |
            _fzf --preview-window right:70% \
              --preview '${pkgs.git}/bin/git show --color=always {} | head -'$LINES
          }
          fzf_pick_git_remote() {
            is_in_git_repo || return
            ${pkgs.git}/bin/git remote -v | ${pkgs.gawk}/bin/awk '{print $1 "\t" $2}' | uniq |
            _fzf --tac \
              --preview '${pkgs.git}/bin/git log --oneline --graph --date=short --pretty="format:%C(auto)%cd %h%d %s" {1} | head -200' |
            cut -d$'\t' -f1
          }
          fzf_pick_git_branch() {
            is_in_git_repo || return
            ${pkgs.git}/bin/git branch -a --color=always | grep -v '/HEAD\s' | sort |
            _fzf  --tac --preview-window right:70% \
              --preview '${pkgs.git}/bin/git log --oneline --graph --date=short --color=always --pretty="format:%C(auto)%cd %h%d %s" $(sed s/^..// <<< {} | cut -d" " -f1) | head -'$LINES |
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
          fzf_git_commit_widget() {
              LBUFFER+=$(fzf_pick_git_commit | join-lines)
          }
          fzf_git_tag_widget() {
              LBUFFER+=$(fzf_pick_git_tag | join-lines)
          }
          fzf_git_remote_widget() {
              LBUFFER+=$(fzf_pick_git_remote | join-lines)
          }
          fzf_git_branch_widget() {
              LBUFFER+=$(fzf_pick_git_branch | join-lines)
          }
          fzf_pick_aws_profile() {
            aws_profile=$(grep '\[profile .*\]' "$HOME/.aws/config" | cut -d' ' -f2 | rev | cut -c 2- | rev | _fzf)
            export AWS_PROFILE="$aws_profile"
          }
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

          # this is not how keys and commands are bound in vanilla ZSH, this
          # pattern is due to ZVM.
          zvm_define_widget fzf_git_commit_widget
          zvm_define_widget fzf_git_tag_widget
          zvm_define_widget fzf_git_remote_widget
          zvm_define_widget fzf_git_branch_widget
          zvm_define_widget fzf_pick_aws_profile
          zvm_define_widget fzf_pick_kube_config

          # easily cycle through history with up and down arrow
          zvm_bindkey viins "^[[A" history-beginning-search-backward
          zvm_bindkey viins "^[[B" history-beginning-search-forward
          # overwrite defaul bindigns
          zvm_bindkey viins "^P" history-beginning-search-backward
          zvm_bindkey viins "^N" history-beginning-search-forward

          # g is for git
          zvm_bindkey viins '^[g^[g' fzf_git_commit_widget
          zvm_bindkey viins '^[g^[t' fzf_git_tag_widget
          zvm_bindkey viins '^[g^[r' fzf_git_remote_widget
          zvm_bindkey viins '^[g^[b' fzf_git_branch_widget

          # p is for profile
          zvm_bindkey viins '^[p^[a' fzf_pick_aws_profile
          zvm_bindkey vicmd '^[p^[a' fzf_pick_aws_profile
          # pk for kube is obvious, but the k binding is used to go down a pane
          zvm_bindkey viins '^[p^[z' fzf_pick_kube_config
          zvm_bindkey vicmd '^[p^[z' fzf_pick_kube_config

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
          export SPACESHIP_TIMETRACK_PREFIX="for "
          export SPACESHIP_KUBECONTEXT_COLOR_GROUPS=(
            # red if namespace is "kube-system"
            green  dev
            yellow staging
            red    prod
          )
          export SPACESHIP_PROMPT_ORDER=(
            time          # Time stamps section
            user          # Username section
            dir           # Current directory section
            timetrack     # What am I working on
            host          # Hostname section
            git           # Git section (git_branch + git_status)
            golang        # Go section
            rust          # Rust section
            haskell       # Haskell Stack section
            docker        # Docker section
            aws           # Amazon Web Services section
            venv          # virtualenv section
            pyenv         # Pyenv section
            dotnet        # .NET section
            kubectl       # Kubectl context section
            terraform     # Terraform workspace section
            exec_time     # Execution time
            line_sep      # Line break
            battery       # Battery level and status
            vi_mode       # Vi-mode indicator
            jobs          # Background jobs indicator
            exit_code     # Exit code section
            char          # Prompt character
          )
          export SPACESHIP_GIT_STATUS_SHOW=false

          SPACESHIP_TIMETRACK_SHOW="''${SPACESHIP_TIMETRACK_SHOW=true}"
          SPACESHIP_TIMETRACK_PREFIX="''${SPACESHIP_TIMETRACK_PREFIX="$SPACESHIP_PROMPT_DEFAULT_PREFIX"}"
          SPACESHIP_TIMETRACK_SUFFIX="''${SPACESHIP_TIMETRACK_SUFFIX="$SPACESHIP_PROMPT_DEFAULT_SUFFIX"}"
          SPACESHIP_TIMETRACK_SYMBOL="''${SPACESHIP_TIMETRACK_SYMBOL="🛠️  "}"
          SPACESHIP_TIMETRACK_COLOR="''${SPACESHIP_TIMETRACK_COLOR="white"}"

          # todo: add this to foundry's contrib and source it
          spaceship_timetrack() {
            [[ $SPACESHIP_TIMETRACK == false ]] && return

            # Use quotes around unassigned local variables to prevent
            # getting replaced by global aliases
            # http://zsh.sourceforge.net/Doc/Release/Shell-Grammar.html#Aliasing
            local 'timetrack_status'

            [[ -d $FOUNDRY_DATA/.tracking ]] || return
            # todo: check if tracking file exsits

            most_recent_tracking_file=$(${pkgs.fd}/bin/fd --type=file . $FOUNDRY_DATA/.tracking | sort | tail -n1)
            [[ -f $most_recent_tracking_file ]] || return
            most_recent_tracking_timestamp=$(basename $most_recent_tracking_file)
            timetrack_status=$(cat $most_recent_tracking_file)

            # Exit section if variable is empty
            [[ -z $timetrack_status ]] && return

            # Display foobar section
            spaceship::section \
              "$SPACESHIP_TIMETRACK_COLOR" \
              "$SPACESHIP_TIMETRACK_PREFIX" \
              "$SPACESHIP_TIMETRACK_SYMBOL$timetrack_status" \
              "$SPACESHIP_TIMETRACK_SUFFIX"
          }

          git() {
            # this regex checks (hopefully) the following cases:
            #   push --force
            #   push -f
            #   push --foo --force
            #   push --foo -f
            #   push --force --foo
            #   push --f --foo
            if echo $@ | ${pkgs.ripgrep}/bin/rg --quiet 'push .*(-f|--force)( |$)'; then
              # todo: refactor colors to a general funciton
              RED='\033[0;31m'
              NC='\033[0m' # No Color
              # write to stderr
              >&2 echo -e "''${RED}Whoa there cowboy! Perhaps you should use --force-with-lease instead of ruining someone's day.''${NC}"
              >&2 echo "''${RED}If you really want to --force, call the git binary directly.''${NC}"
              >&2 echo "''${RED}    ${pkgs.git}/bin/git''${NC}"
              return 1
            else
              ${pkgs.git}/bin/git "$@"
            fi
          }

          # tmux-fzf config
          # https://github.com/sainnhe/tmux-fzf
          export TMUX_FZF_ORDER="window|session|pane|command|keybinding"

          eval "$(jira --completion-script-zsh)"

          # PS$ is used when command printing (`set -x`) it turned on. The will
          # print the scripts, function, and line number.
          #
          # see `man bash` for available expansions
          # https://news.ycombinator.com/item?id=27617128
          #
          export PS4='+ ''${BASH_SOURCE:-}:''${FUNCNAME[0]:-}:L${LINENO:-}:   '

          # todo: set this up on just paige macbook
          # how to setup zsh completion with multiple repositores
          # https://github.com/zx2c4/password-store/blob/3dd14690c7c81ac80e32e942cf5976732faf0fb3/src/completion/pass.zsh-completion#L12-L18
          compdef _pass paigepass
          zstyle ':completion::complete:paigepass::' prefix "$HOME/.paige-passwords"
          paigepass() {
            PASSWORD_STORE_DIR=$HOME/.paige-passwords pass $@
          }
        '';
      };
      fzf = {
        enable = true;
        enableZshIntegration = true;
        defaultOptions = [
          "--no-height --no-reverse"
        ];
        historyWidgetOptions = [
          "--preview 'echo {}' --preview-window down:3"
        ];
      };
    };
  };
}
