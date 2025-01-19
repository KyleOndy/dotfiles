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
        autosuggestion = {
          enable = true;
          highlight = "fg=6";
        };
        autocd = false; # I can't stand when ZSH Decided to change my directory
        history = {
          extended = true; # save timestamps
          ignoreDups = true;
          save = 1000000; # lots of history. Internal history list
          size = 1000000; # lots of history. Save to file.
          share = true; # let multiple ZSH session write to the history file
        };
        sessionVariables = {
          ZVM_VI_EDITOR = "$EDITOR";
        };
        shellAliases = {
          ":e" = "$EDITOR";
          ":q" = "exit";
          ":Q" = "exit";
          cdf = "cd $FOUNDRY_DATA";
          cdtmp = "cd $(mktemp -d)";
          cdg = "cd $(git root)";
          e = "sort -u | xargs --no-run-if-empty -- $EDITOR --";
          f = "foundry";
          g = "git";
          j = "bat --language=json $@";
          k = "kubectl";
          l = "bat --style=plain --paging=never --language=log $@";
          llr = "ll --color=auto -t | head";
          lsd = "ls -l $@ | grep '^d'";
          src = "cd ${config.home.homeDirectory}/src";
          src_grep = "fd --type=f --full-path --regex '(/master/|/main/)' --print0 . ${config.home.homeDirectory}/src/ | xargs --null -- rg \"$@\" --";
          tree = "tree --dirsfirst -ChFQ $@";
          tree1 = "tree -L 1 $@";
          tree2 = "tree -L 2 $@";
          tree3 = "tree -L 3 $@";
          y = "bat --language yaml $@";
          ygron = "yq --output-format=props"; # like gron, for yaml
        };
        # The double single quote `''` is to escape the `${` character
        # combination that nix wants to replace with a variable. Its not some
        # fancy bash trick. In the bash source, the double quotes do not
        # appear.
        initExtraFirst = ''
          # do this early, so I can overwrite settings as I want.
          source ${pkgs.zsh-vi-mode}/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh
        '';
        initExtra = ''
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
          # reduce <ESC> key timeout in vim mode
          export KEYTIMEOUT=50

          # my quality of life functions

          # nicer autocomplete selections
          zstyle ':completion:*' menu select # use arrows to navigate autocomplete results
          zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}' # lowers match uppers

          setopt ignoreeof # don't close my shell on ^d. Why is that a good idea?

          find_up() {
            local ec=1
            local p=$(pwd)
            while [[ "$p" != "" ]]; do
              if [[ -e "$p/$1" ]]; then
                echo "$p/$1"
                ec=0
              fi
              p=''${p%/*}
            done
            return $ec
          }

          # fancy git + fzf
          is_in_git_repo() {
            ${pkgs.git}/bin/git rev-parse HEAD > /dev/null 2>&1
          }
          _fzf() {
            ${pkgs.fzf}/bin/fzf "$@" --multi --ansi --border
          }
          fzf_pick_git_worktree() {
            is_in_git_repo || return
            # this will break if a worktree name has a newline, didn't want to deal with null terminators
            worktree=$(
              ${pkgs.git}/bin/git worktree list | rg --invert-match '\(bare\)$'| ${pkgs.fzf}/bin/fzf \
                --prompt="Switch Worktree: " \
                --height 40% --reverse \
                --preview-window down \
                --preview 'git log --oneline --graph --date=short --pretty="format:%C(auto)%cd %h%d %s" --color=always "$(echo {} | rg -v --regexp ".bare" | sed -E "s/^.*\[(.+)\]$/\1/g")"' | \
                awk '{print $1}'
            )
            cd "$worktree" || return
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

          fzf_pick_git_repository() {
            src_root="''${HOME}/src"
            repo_bare=$(fd --type=d --max-depth=4 --hidden .bare "''${src_root}")

            stripped_repo="''${repo_bare//"''${src_root}"\//}"
            bare_repo=''${stripped_repo//.bare\//}

            repo=$(echo "''${bare_repo}" | fzf)
            for dir in "''${HOME}/src/''${repo}/main" "''${HOME}/src/''${repo}/master" "''${HOME}/src/''${repo}"; do
              if [[ -d "''${dir}" ]]; then
                pushd "''${dir}" > /dev/null && return
              fi
            done
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

          _reset_prompt() {
            local precmd
            for precmd in $precmd_functions; do
              $precmd
            done
            zle reset-prompt
          }

          fzf_git_switch_worktree_widget() {
            fzf_pick_git_worktree
            _reset_prompt
          }

          fzf_git_commit_widget() {
              LBUFFER+=$(fzf_pick_git_commit | join-lines)
          }

          fzf_git_tag_widget() {
              LBUFFER+=$(fzf_pick_git_tag | join-lines)
          }

          fzf_git_repository_widget() {
            fzf_pick_git_repository
            _reset_prompt
          }

          fzf_git_branch_widget() {
              LBUFFER+=$(fzf_pick_git_branch | join-lines)
          }

          fzf_pick_aws_profile() {
            aws_profile=$(grep '\[profile .*\]' "${config.home.homeDirectory}/.aws/config" | cut -d' ' -f2 | rev | cut -c 2- | rev | _fzf)
            if [[ -z "$aws_profile" ]]; then
              unset AWS_PROFILE
            else
              export AWS_PROFILE="$aws_profile"
            fi
            _reset_prompt
          }

          # easily export which kube config I want. I can't break things if I can
          # not connect to the cluster.
          fzf_pick_kube_config() {
            config_dir="${config.home.homeDirectory}/.kube/configs"
            # becuase at $WORK I use darwin, I don't have GNU find, and need to do
            # these shenanigans with `basename`.
            kubeconfig=$(find "$config_dir" -type f -exec basename {} \; | sort |
            _fzf --preview "bat --color=always "$config_dir/{}"")

            if [[ -z "$kubeconfig" ]]; then
              unset KUBECONFIG
            else
              export KUBECONFIG="$config_dir/$kubeconfig"
            fi
            _reset_prompt
          }

          fzf_pick_k8s_cluster() {
            config_dir="${config.home.homeDirectory}/.kube/configs"
            kubeconfig=$(fd --type=f . $HOME/.kube/configs --exclude gke_gcloud_auth_plugin_cache -x basename {} |
              sort | _fzf --preview "bat --color=always -l=yaml "$config_dir/{}"")


            if [[ -z "$kubeconfig" ]]; then
              unset KUBECONFIG
              unset AWS_PROFILE
              unset AWS_REGION
            else
              KUBECONFIG="$config_dir/$kubeconfig"
              AWS_PROFILE=$(yq '.users[].user.exec.env[] | select(.name == "AWS_PROFILE") | .value' "$KUBECONFIG")
              AWS_REGION=$(yq '.users[].user.exec.args' "$KUBECONFIG" | rg -F -e '--region' -A1 | tail -n1 | cut -d' ' -f2)

              # This checks if the cluster is AWS
              # TODO: handle GKE cluster
              if [[ -n $AWS_PROFILE ]] && [[ -n $AWS_REGION ]]; then
                aws_sso_login "$AWS_PROFILE"
                export AWS_PROFILE
                export AWS_REGION
                export KUBECONFIG
              fi
            fi
            _reset_prompt
          }

          aws_sso_login() {
            local profile=$1

            aws --profile "$profile" sts get-caller-identity > /dev/null 2>&1 || aws --profile "$profile" sso login
          }

          # this is not how keys and commands are bound in vanilla ZSH, this
          # pattern is due to ZVM.
          zvm_define_widget fzf_git_switch_worktree_widget
          zvm_define_widget fzf_git_commit_widget
          zvm_define_widget fzf_git_tag_widget
          zvm_define_widget fzf_git_repository_widget
          zvm_define_widget fzf_git_branch_widget
          zvm_define_widget fzf_pick_aws_profile
          zvm_define_widget fzf_pick_kube_config
          zvm_define_widget fzf_pick_k8s_cluster

          # easily cycle through history with up and down arrow
          zvm_bindkey viins "^[[A" history-beginning-search-backward
          zvm_bindkey viins "^[[B" history-beginning-search-forward
          # overwrite defaul bindigns
          zvm_bindkey viins "^P" history-beginning-search-backward
          zvm_bindkey viins "^N" history-beginning-search-forward

          # g is for git
          zvm_bindkey viins '^[g^[w' fzf_git_switch_worktree_widget
          zvm_bindkey viins '^[g^[g' fzf_git_commit_widget
          zvm_bindkey viins '^[g^[t' fzf_git_tag_widget
          zvm_bindkey viins '^[g^[r' fzf_git_repository_widget
          zvm_bindkey viins '^[g^[b' fzf_git_branch_widget

          # p is for profile
          zvm_bindkey viins '^[p^[a' fzf_pick_aws_profile
          zvm_bindkey vicmd '^[p^[a' fzf_pick_aws_profile
          # pk for kube is obvious, but the k binding is used to go down a pane
          zvm_bindkey viins '^[p^[z' fzf_pick_kube_config
          zvm_bindkey vicmd '^[p^[z' fzf_pick_kube_config

          # make some assumptions and setup AWS envvars along with k8s
          zvm_bindkey viins '^[p^[p' fzf_pick_k8s_cluster
          zvm_bindkey vicmd '^[p^[p' fzf_pick_k8s_cluster

          # https://book.babashka.org/#_terminal_tab_completion
          _bb_tasks() {
            local matches=(`bb tasks |tail -n +3 |cut -f1 -d ' '`)
            compadd -a matches
            _files # autocomplete filenames as well
          }
          compdef _bb_tasks bb

          # spaceship config
          source "${pkgs.spaceship-prompt}/lib/spaceship-prompt/spaceship.zsh"
          export SPACESHIP_PROMPT_ASYNC=false # https://github.com/spaceship-prompt/spaceship-prompt/issues/1193

          # Here are some symbols I'd love to use somewhere
          #  U+2615   HOT BEVERAGE          ☕
          #  U+2620   SKULL AND CROSSBONES  ☠
          #  U+2622   RADIOACTIVE SIGN      ☢
          export SPACESHIP_CHAR_SYMBOL='λ '
          export SPACESHIP_CHAR_SYMBOL_ROOT='☢ '
          export SPACESHIP_TIME_SHOW=true
          export SPACESHIP_KUBECTL_SHOW=true
          export SPACESHIP_KUBECTL_VERSION_SHOW=false # don't care what version
          export SPACESHIP_WTROOT_PREFIX="for "
          export SPACESHIP_PROMPT_ORDER=(
            time          # Time stamps section
            user          # Username section
            dir           # Current directory section
            host          # Hostname section
            wtroot        # hacky homegrown worktree root
            git           # Git section (git_branch + git_status)
            golang        # Go section
            rust          # Rust section
            haskell       # Haskell Stack section
            aws           # Amazon Web Services section
            venv          # virtualenv section
            python        # python section
            dotnet        # .NET section
            kubectl       # Kubectl context section
            terraform     # Terraform workspace section
            exec_time     # Execution time
            line_sep      # Line break
            battery       # Battery level and status
            jobs          # Background jobs indicator
            exit_code     # Exit code section
            char          # Prompt character
          )
          export SPACESHIP_GIT_STATUS_SHOW=false

          SPACESHIP_WTROOT_SHOW="''${SPACESHIP_WTROOT_SHOW=true}"
          SPACESHIP_WTROOT_PREFIX="''${SPACESHIP_WTROOT_PREFIX="$SPACESHIP_PROMPT_DEFAULT_PREFIX"}"
          SPACESHIP_WTROOT_SUFFIX="''${SPACESHIP_WTROOT_SUFFIX=$SPACESHIP_PROMPT_DEFAULT_SUFFIX}"
          SPACESHIP_WTROOT_SYMBOL="''${SPACESHIP_WTROOT_SYMBOL=" "}"
          SPACESHIP_WTROOT_COLOR="''${SPACESHIP_WTROOT_COLOR="yellow"}"

          spaceship_wtroot() {
            [[ $SPACESHIP_WTROOT_SHOW == false ]] && return
            # todo: if not git; bail

            # TODO: should set SPACESHIP_GIT_SHOW to some original value
            results=$(find_up .bare | head -n1)
            if [[ -z "$results" ]]; then
              SPACESHIP_GIT_SHOW=true
              return
            fi

            # HACKS ON HACKS
            #                 if we are in a "root" of a worktree, but not in a
            #                 checked-out worktree, we don't want spaceship to
            #                 display the git status or we always get the
            #                 `fatal: this operation must be run in a work
            #                 tree` error which is really annyoing. So turn of
            #                 spaceship's git prompt iif we are "between"
            #                 `.bare` and a checked out worktree.
            ${pkgs.git}/bin/git rev-parse --show-toplevel > /dev/null 2>&1 || SPACESHIP_GIT_SHOW=false

            result=$(basename $(dirname $(echo "$results" | head -n1)))
            spaceship::section::v4 \
              --color  "$SPACESHIP_WTROOT_COLOR" \
              --prefix "$SPACESHIP_WTROOT_PREFIX" \
              --suffix "$SPACESHIP_WTROOT_SUFFIX" \
              --symbol "$SPACESHIP_WTROOT_SYMBOL" \
              "$result"
          }

          git() {
            # TODO: add more sanity checks for me locally
            #   - if in a worktree project, don't allow checking out a branch if on master or main

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

          # PS$ is used when command printing (`set -x`) it turned on. The will
          # print the scripts, function, and line number.
          #
          # see `man bash` for available expansions
          # https://news.ycombinator.com/item?id=27617128
          #
          export PS4='+ %D{%s.%6.}: %x @ %I: (%N):    '

          # A bash variable may appear strange in a zsh config. This is really
          # for a single specific reason. When I am writing a bash script and I
          # `set -x` without this the bash script runs with zsh's PS4 above.
          # This outputs just junk. I have a bash PS4 set is bashrc and I want
          # to use that when a non-interactive non-login shell is staeted. This
          # is fairly safe since this bashrc checks if it is invoked as an
          # interactive and exits pretty early if so.
          export BASH_ENV=$HOME/.bashrc

          assume_aws_role() {
            local role_arn=$1
            response=$(aws sts assume-role --role-arn "$role_arn" --role-session-name todo)
            export AWS_ACCESS_KEY_ID=$(echo "$response" | jq -r '.Credentials.AccessKeyId')
            export AWS_SECRET_ACCESS_KEY=$(echo "$response" | jq -r '.Credentials.SecretAccessKey')
            export AWS_SESSION_TOKEN=$(echo "$response" | jq -r '.Credentials.SessionToken')
          }

          reset_aws_envvars() {
            unset AWS_ACCESS_KEY_ID
            unset AWS_REGION
            unset AWS_SECRET_ACCESS_KEY
            unset AWS_SESSION_TOKEN
          }

          man_http() {
            # from 'danstewart_' via https://news.ycombinator.com/item?id=32165027
            local code="$1"
            if [[ -z $code ]]; then
              echo "Usage: man-http <status code>"
              exit 0
            fi

            open "https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/$code"
          }

          print_http_status_codes() {
            # inspired by 'capableweb' via https://news.ycombinator.com/item?id=32165943
            # to update this list: `curl --silent https://developer.mozilla.org/en-US/docs/Web/HTTP/Status | htmlq --text 'dt a code'`
            # Keeping this in text to keep it _fast_ and it works offline.
            cat << EOF
          100 Continue
          101 Switching Protocols
          102 Processing
          103 Early Hints
          200 OK
          201 Created
          202 Accepted
          203 Non-Authoritative Information
          204 No Content
          205 Reset Content
          206 Partial Content
          207 Multi-Status
          208 Already Reported
          226 IM Used
          300 Multiple Choices
          301 Moved Permanently
          302 Found
          303 See Other
          304 Not Modified
          307 Temporary Redirect
          308 Permanent Redirect
          400 Bad Request
          401 Unauthorized
          402 Payment Required
          403 Forbidden
          404 Not Found
          405 Method Not Allowed
          406 Not Acceptable
          407 Proxy Authentication Required
          408 Request Timeout
          409 Conflict
          410 Gone
          411 Length Required
          412 Precondition Failed
          413 Payload Too Large
          414 URI Too Long
          415 Unsupported Media Type
          416 Range Not Satisfiable
          417 Expectation Failed
          418 I'm a teapot
          421 Misdirected Request
          422 Unprocessable Entity
          423 Locked
          424 Failed Dependency
          425 Too Early
          426 Upgrade Required
          428 Precondition Required
          429 Too Many Requests
          431 Request Header Fields Too Large
          451 Unavailable For Legal Reasons
          500 Internal Server Error
          501 Not Implemented
          502 Bad Gateway
          503 Service Unavailable
          504 Gateway Timeout
          505 HTTP Version Not Supported
          506 Variant Also Negotiates
          507 Insufficient Storage
          508 Loop Detected
          510 Not Extended
          511 Network Authentication Required
          EOF
          }

          # Yucky homebrew. Don't like mixing it with nix, but its work stuff,
          # so can't push back too hard.

          _include () {
            [[ -f "$1" ]] && source "$1"
          }

          # TODO: rip out all evals
          if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
          fi

          _include /opt/homebrew/opt/asdf/libexec/asdf.sh

          source ${pkgs.zsh-histdb}/sqlite-history.zsh
          autoload -Uz add-zsh-hook
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
      dircolors.enable = true;
    };
  };
}
