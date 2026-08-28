{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.shell.zsh;
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
          # Values never reach argv, but the entry names alone inventory
          # every account worth attacking, and a search-mail argument is
          # the query text itself. zsh-histdb honours HISTORY_IGNORE too
          # (sqlite-history.zsh:145), so one pattern covers both stores.
          ignorePatterns = [
            "pass *"
            "search-mail *"
          ];
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
          cdtmp = "cd $(mktemp -d)";
          cdg = "cd $(git root)";
          claude-caffeine =
            if pkgs.stdenv.isLinux then
              "systemd-inhibit --what=idle:sleep:handle-lid-switch --who='Claude Code' --why='Active AI coding session' claude"
            else
              "caffeinate -disu claude";
          e = "sort -u | xargs --no-run-if-empty -- $EDITOR --";
          g = "git";
          j = "bat --language=json $@";
          k = "kubectl";
          l = "bat --style=plain --paging=never --language=log $@";
          llr = "ll --color=auto -t | head";
          lsd = "ls -l $@ | grep '^d'";
          serve = "miniserve . --dirs-first --upload-files";
          src = "cd ${config.home.homeDirectory}/src";
          src_grep = "fd --type=f --full-path --regex '(/master/|/main/)' --print0 . ${config.home.homeDirectory}/src/ | xargs --null -- rg \"$@\" --";
          tree = "tree --dirsfirst -ChFQ $@";
          tree1 = "tree -L 1 $@";
          tree2 = "tree -L 2 $@";
          tree3 = "tree -L 3 $@";
          work = "cd ${config.home.homeDirectory}/work";
          y = "bat --language yaml $@";
          ygron = "yq --output-format=props"; # like gron, for yaml
        };
        # The double single quote `''` is to escape the `${` character
        # combination that nix wants to replace with a variable. Its not some
        # fancy bash trick. In the bash source, the double quotes do not
        # appear.
        initContent = lib.mkMerge [
          # mkOrder 100 runs before mkBefore (order 500) and before Home Manager's
          # compinit call (order 500). This ensures fpath is set before completion
          # system initialization.
          (lib.mkOrder 100 ''
            fpath=(~/.local/share/zsh/site-functions $fpath)
          '')
          (lib.mkBefore ''
            # zvm reads every ZVM_* setting while it is being sourced, so an
            # assignment after the source below is too late. zvm_config is the
            # hook it calls just before dispatching on ZVM_INIT_MODE.
            # https://github.com/jeffreytse/zsh-vi-mode/blob/v0.12.0/zsh-vi-mode.zsh#L306
            zvm_config() {
              # The default lazy mode registers zvm_init as a precmd hook, so
              # the widget table gets rewritten on the first prompt, in the same
              # callhookfunc pass that runs zsh-autosuggestions'
              # `$(builtin zle -la)`. Reading it mid-rewrite segfaults zsh:
              # 7 coredumps in 48h on tiger, all in zle.so under execbuiltin.
              # https://github.com/jeffreytse/zsh-vi-mode/blob/v0.12.0/zsh-vi-mode.zsh#L4034-L4037
              ZVM_INIT_MODE=sourcing

              # Only changing the escape key to `jk` in insert mode, we still
              # keep using the default keybindings `^[` in other modes
              ZVM_VI_INSERT_ESCAPE_BINDKEY=jk
              # I never _intend_ or _expect_ to start in normal mode and it throws
              # me off every time.
              ZVM_LINE_INIT_MODE=$ZVM_MODE_INSERT
            }

            zvm_after_init() {
              # White ZVM is super nifty, and better than the built in vi mode,
              # it does clobber some key bindings; here we source FZF to get
              # those bindings back.
              #
              # https://github.com/jeffreytse/zsh-vi-mode/issues/24
              source "${pkgs.fzf}/share/fzf/key-bindings.zsh"
              source "${pkgs.fzf}/share/fzf/completion.zsh"

              # Initialize starship prompt AFTER zvm finishes to prevent prompt corruption
              # https://github.com/jeffreytse/zsh-vi-mode#execute-extra-commands
              eval "$(${pkgs.starship}/bin/starship init zsh)"
            }

            # do this early, so I can overwrite settings as I want.
            source ${pkgs.zsh-vi-mode}/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh
          '')
          ''
            # zsh tweaks not included in home-manager.
            # reduce <ESC> key timeout in vim mode
            export KEYTIMEOUT=50

            # Cache management for expensive operations
            # Global cache storage
            typeset -gA _cache_data
            typeset -gA _cache_time
            readonly CACHE_TTL=300 # 5 minutes

            # Get cached value if valid, returns 1 if cache miss
            _cache_get() {
              local key="$1"
              local now=$EPOCHSECONDS
              if [[ -n "''${_cache_time[$key]}" ]] && (( now - _cache_time[$key] < CACHE_TTL )); then
                echo "''${_cache_data[$key]}"
                return 0
              fi
              return 1
            }

            # Store value in cache with current timestamp
            _cache_set() {
              local key="$1"
              local value="$2"
              _cache_data[$key]="$value"
              _cache_time[$key]=$EPOCHSECONDS
            }

            # my quality of life functions

            # nicer autocomplete selections
            zstyle ':completion:*' menu select # use arrows to navigate autocomplete results
            zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}' # lowers match uppers

            setopt ignoreeof # don't close my shell on ^d. Why is that a good idea?

            find_up() {
              local p=$(pwd)
              while [[ "$p" != "" ]]; do
                if [[ -e "$p/$1" ]]; then
                  echo "$p/$1"
                  return 0
                fi
                p=''${p%/*}
              done
              return 1
            }

            # fancy git + fzf
            is_in_git_repo() {
              ${pkgs.git}/bin/git rev-parse --git-dir > /dev/null 2>&1
            }
            _fzf() {
              ${pkgs.fzf}/bin/fzf "$@" --multi --ansi --border
            }
            fzf_pick_git_worktree() {
              is_in_git_repo || return
              # this will break if a worktree name has a newline, didn't want to deal with null terminators
              local worktree
              worktree=$(
                ${pkgs.git}/bin/git worktree list | ${pkgs.ripgrep}/bin/rg --invert-match '\(bare\)$'| ${pkgs.fzf}/bin/fzf \
                  --prompt="Switch Worktree: " \
                  --height 40% --reverse \
                  --preview-window down \
                  --preview '${pkgs.git}/bin/git log --oneline --graph --date=short --pretty="format:%C(auto)%cd %h%d %s" --color=always "$(echo {} | ${pkgs.ripgrep}/bin/rg -v --regexp ".bare" | ${pkgs.gnused}/bin/sed -E "s/^.*\[(.+)\]$/\1/g")"' | \
                  ${pkgs.gawk}/bin/awk '{print $1}'
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
                --preview '${pkgs.gnugrep}/bin/grep -o "[a-f0-9]\{7,\}" <<< {} | ${pkgs.findutils}/bin/xargs ${pkgs.git}/bin/git show --color=always | ${pkgs.coreutils}/bin/head -'$LINES |
              ${pkgs.gnugrep}/bin/grep -o "[a-f0-9]\{7,\}"
            }

            fzf_pick_git_tag() {
              is_in_git_repo || return
              ${pkgs.git}/bin/git tag --sort -version:refname |
              _fzf --preview-window right:70% \
                --preview '${pkgs.git}/bin/git show --color=always {} | ${pkgs.coreutils}/bin/head -'$LINES
            }

            fzf_pick_git_repository() {
              local src_root="${config.home.homeDirectory}/src"
              local repo_bare stripped_repo bare_repo repo dir

              if ! repo_bare=$(${pkgs.fd}/bin/fd --type=d --max-depth=4 --hidden .bare "${config.home.homeDirectory}/src" 2>/dev/null); then
                echo "Error: Failed to find git repositories" >&2
                return 1
              fi

              if [[ -z "$repo_bare" ]]; then
                echo "Error: No git repositories found in $src_root" >&2
                return 1
              fi

              stripped_repo="''${repo_bare//${config.home.homeDirectory}\/src\//}"
              bare_repo=''${stripped_repo//.bare\//}

              repo=$(echo "''${bare_repo}" | ${pkgs.fzf}/bin/fzf \
                --prompt="Switch Repo: " \
                --height 40% --reverse) || return
              [[ -z "$repo" ]] && return

              for dir in "${config.home.homeDirectory}/src/''${repo}/main" "${config.home.homeDirectory}/src/''${repo}/master" "${config.home.homeDirectory}/src/''${repo}"; do
                if [[ -d "''${dir}" ]]; then
                  pushd "''${dir}" > /dev/null && return
                fi
              done

              echo "Error: No valid worktree found for repository: $repo" >&2
              return 1
            }

            fzf_pick_git_branch() {
              is_in_git_repo || return
              ${pkgs.git}/bin/git branch -a --color=always | ${pkgs.gnugrep}/bin/grep -v '/HEAD\s' | ${pkgs.coreutils}/bin/sort |
              _fzf  --tac --preview-window right:70% \
                --preview '${pkgs.git}/bin/git log --oneline --graph --date=short --color=always --pretty="format:%C(auto)%cd %h%d %s" $(${pkgs.gnugrep}/bin/sed s/^..// <<< {} | ${pkgs.coreutils}/bin/cut -d" " -f1) | ${pkgs.coreutils}/bin/head -'$LINES |
              ${pkgs.gnugrep}/bin/sed 's/^..//' | ${pkgs.coreutils}/bin/cut -d' ' -f1 |
              ${pkgs.gnugrep}/bin/sed 's#^remotes/##'
            }

            # A helper function to join multi-line output from fzf
            join-lines() {
              local item
              while read item; do
                echo -n "''${(q)item} "
              done
            }

            _reset_prompt() {
              # Only run if we're in a ZLE context (defensive check)
              if [[ -o zle ]]; then
                local precmd
                for precmd in $precmd_functions; do
                  # Run precmd functions but don't let errors stop the loop
                  $precmd || true
                done
                zle reset-prompt
                zle -R
              fi
            }

            fzf_git_switch_worktree_widget() {
              fzf_pick_git_worktree && _reset_prompt
            }

            fzf_git_commit_widget() {
                LBUFFER+=$(fzf_pick_git_commit | join-lines)
            }

            fzf_git_tag_widget() {
                LBUFFER+=$(fzf_pick_git_tag | join-lines)
            }

            fzf_git_repository_widget() {
              fzf_pick_git_repository && _reset_prompt
            }

            fzf_git_branch_widget() {
                LBUFFER+=$(fzf_pick_git_branch | join-lines)
            }

            fzf_pick_aws_profile() {
              local aws_profile aws_profiles prompt_prefix

              # Try to get from cache
              if aws_profiles=$(_cache_get "aws_profiles"); then
                prompt_prefix="[cached] "
              else
                # Cache miss - fetch and cache
                aws_profiles=$(${pkgs.gnugrep}/bin/grep '\[profile .*\]' "${config.home.homeDirectory}/.aws/config" | ${pkgs.coreutils}/bin/cut -d' ' -f2 | ${pkgs.util-linux}/bin/rev | ${pkgs.coreutils}/bin/cut -c 2- | ${pkgs.util-linux}/bin/rev)
                _cache_set "aws_profiles" "$aws_profiles"
                prompt_prefix=""
              fi

              aws_profile=$(echo "$aws_profiles" | _fzf --prompt="''${prompt_prefix}AWS Profile: ")
              if [[ -z "$aws_profile" ]]; then
                unset AWS_PROFILE
              else
                export AWS_PROFILE="$aws_profile"
              fi
              _reset_prompt
            }

            fzf_pick_k8s_cluster() {
              local config_dir="${config.home.homeDirectory}/.kube/configs"
              local kubeconfig k8s_clusters prompt_prefix

              # Try to get from cache
              if k8s_clusters=$(_cache_get "k8s_clusters"); then
                prompt_prefix="[cached] "
              else
                # Cache miss - fetch and cache
                k8s_clusters=$(${pkgs.fd}/bin/fd --type=f . $HOME/.kube/configs --exclude gke_gcloud_auth_plugin_cache -x ${pkgs.coreutils}/bin/basename {} | ${pkgs.coreutils}/bin/sort)
                _cache_set "k8s_clusters" "$k8s_clusters"
                prompt_prefix=""
              fi

              kubeconfig=$(echo "$k8s_clusters" | _fzf --prompt="''${prompt_prefix}K8s Cluster: " --preview "${pkgs.bat}/bin/bat --color=always -l=yaml "$config_dir/{}"")

              if [[ -z "$kubeconfig" ]]; then
                unset KUBECONFIG
                unset AWS_PROFILE
                unset AWS_REGION
              else
                export KUBECONFIG="$config_dir/$kubeconfig"
                AWS_PROFILE=$(${pkgs.yq-go}/bin/yq '.users[].user.exec.env[] | select(.name == "AWS_PROFILE") | .value' "$KUBECONFIG")
                AWS_REGION=$(${pkgs.yq-go}/bin/yq '.users[].user.exec.args' "$KUBECONFIG" | ${pkgs.ripgrep}/bin/rg -F -e '--region' -A1 | ${pkgs.coreutils}/bin/tail -n1 | ${pkgs.coreutils}/bin/cut -d' ' -f2)

                # TODO: handle GKE cluster
                if [[ -n $AWS_PROFILE ]] && [[ -n $AWS_REGION ]]; then
                  aws_sso_login "$AWS_PROFILE"
                  export AWS_PROFILE
                  export AWS_REGION
                else
                  # Clusters authenticating with a static token carry no AWS
                  # identity. Keeping the previous pick's profile exported would
                  # aim kubectl and aws at different accounts.
                  unset AWS_PROFILE
                  unset AWS_REGION
                fi
              fi
              _reset_prompt
            }

            aws_sso_login() {
              local profile=$1

              ${pkgs.awscli2}/bin/aws --profile "$profile" sts get-caller-identity > /dev/null 2>&1 || ${pkgs.awscli2}/bin/aws --profile "$profile" sso login
            }

            # this is not how keys and commands are bound in vanilla ZSH, this
            # pattern is due to ZVM.
            zvm_define_widget fzf_git_switch_worktree_widget
            zvm_define_widget fzf_git_commit_widget
            zvm_define_widget fzf_git_tag_widget
            zvm_define_widget fzf_git_repository_widget
            zvm_define_widget fzf_git_branch_widget
            zvm_define_widget fzf_pick_aws_profile
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
            # pk for kube is obvious, but the k binding is used to go down a pane.
            # Picks the kubeconfig and sets the matching AWS envvars with it.
            zvm_bindkey viins '^[p^[p' fzf_pick_k8s_cluster
            zvm_bindkey vicmd '^[p^[p' fzf_pick_k8s_cluster

            # https://book.babashka.org/#_terminal_tab_completion
            _bb_tasks() {
              local matches=($(bb tasks | ${pkgs.coreutils}/bin/tail -n +3 | ${pkgs.coreutils}/bin/cut -f1 -d ' '))
              compadd -a matches
              _files # autocomplete filenames as well
            }
            compdef _bb_tasks bb

            git() {
              # TODO: add more sanity checks for me locally
              #   - if in a worktree project, don't allow checking out a branch if on master or main

              # Fast path: skip check for non-push commands (99% of git usage)
              if [[ "$1" != "push" ]]; then
                ${pkgs.git}/bin/git "$@"
                return
              fi

              # Only check for --force flags on push commands
              local arg
              for arg in "$@"; do
                if [[ "$arg" == "-f" ]] || [[ "$arg" == "--force" ]]; then
                  # todo: refactor colors to a general function
                  local RED='\033[0;31m'
                  local NC='\033[0m' # No Color
                  # write to stderr
                  >&2 echo -e "''${RED}Whoa there cowboy! Perhaps you should use --force-with-lease instead of ruining someone's day.''${NC}"
                  >&2 echo -e "''${RED}If you really want to --force, call the git binary directly.''${NC}"
                  >&2 echo -e "''${RED}    ${pkgs.git}/bin/git''${NC}"
                  return 1
                fi
              done

              ${pkgs.git}/bin/git "$@"
            }

            # tmux-fzf config
            # https://github.com/sainnhe/tmux-fzf
            export TMUX_FZF_ORDER="window|session|pane|command|keybinding"

            # PS4 is used when command printing (`set -x`) is turned on. This
            # prints the script, function, and line number.
            #
            # Deliberately not exported. PS4 is only read by the shell doing the
            # tracing, so zsh has no reason to hand it to children -- and if it
            # does, a child bash inherits these zsh %-escapes and prints them
            # literally: "+ %D{%s.%6.}: %x @ %I: (%N):    echo hi". Bash gets
            # its own PS4 from BASH_ENV instead (see shell/bash.nix).
            #
            # see `man zshmisc` for available expansions
            # https://news.ycombinator.com/item?id=27617128
            PS4='+ %D{%s.%6.}: %x @ %I: (%N):    '

            assume_aws_role() {
              local role_arn=$1
              local response

              if [[ -z "$role_arn" ]]; then
                echo "Error: Role ARN is required" >&2
                echo "Usage: assume_aws_role <role-arn>" >&2
                return 1
              fi

              if ! response=$(${pkgs.awscli2}/bin/aws sts assume-role --role-arn "$role_arn" --role-session-name todo 2>&1); then
                echo "Error: Failed to assume role: $role_arn" >&2
                echo "$response" >&2
                return 1
              fi

              export AWS_ACCESS_KEY_ID=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.Credentials.AccessKeyId')
              export AWS_SECRET_ACCESS_KEY=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.Credentials.SecretAccessKey')
              export AWS_SESSION_TOKEN=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.Credentials.SessionToken')
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
                return 0
              fi

              local url="https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/$code"
              if [[ "$OSTYPE" == "darwin"* ]]; then
                open "$url"
              else
                xdg-open "$url"
              fi
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

            source ${pkgs.zsh-histdb}/share/zsh-histdb/sqlite-history.zsh
            autoload -Uz add-zsh-hook

            export PATH="$HOME/bin:$PATH"

            private() {
              # zsh-histdb records from its own zshaddhistory hook and reads
              # neither HISTFILE nor SAVEHIST, so dropping those alone leaves
              # the sqlite database, and the backups it ships to tiger,
              # recording every command.
              unset HISTFILE
              SAVEHIST=0
              add-zsh-hook -d zshaddhistory _histdb_addhistory
              cd "$(mktemp -d)" || return
              echo "Private mode enabled in $PWD"
            }

            wt_notes() {
              local git_dir
              git_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || {
                echo "Not in a git worktree" >&2
                return 1
              }
              $EDITOR "$(dirname "$git_dir")/notes.txt"
            }

            _wt_slug() {
              setopt localoptions extendedglob
              local s=''${(L)1} full
              s=''${s//[^a-z0-9]##/-}
              s=''${s##-}
              s=''${s%%-}
              full=$s
              s=''${s[1,40]}
              # Truncation landed mid-word, so drop the partial tail.
              [[ $s != $full ]] && s=''${s%-*}
              print -r -- ''${s%%-}
            }

            # git wt-feature-branch bases on origin/<default>. Branch from the
            # local one instead: main here routinely carries commits that have
            # not been pushed, and they belong in the new worktree.
            _wt_base() {
              local b
              for b in main master; do
                if git show-ref --verify --quiet "refs/heads/$b"; then
                  print -r -- "$b"
                  return
                fi
              done
              git rev-parse --abbrev-ref HEAD
            }

            # A function, not a script in my-scripts: only the calling shell
            # can change its own directory. Same reason fzf_pick_git_worktree
            # lives here.
            wt() {
              # Not `path`: zsh ties that name to $PATH, so declaring it local
              # empties PATH for the rest of the function.
              local wt_path wt_ticket wt_title wt_slug

              # A bare ticket takes its name from the issue title.
              if (( $# == 1 )) && [[ $1 =~ '^[A-Za-z]+-[0-9]+$' ]]; then
                wt_ticket=''${(U)1}
                wt_title=$(linear issue title "$wt_ticket" 2>/dev/null) \
                  && wt_slug=$(_wt_slug "$wt_title")
                if [[ -n $wt_slug ]]; then
                  set -- "$wt_ticket" "$wt_slug"
                else
                  set -- "$wt_ticket"
                fi
              fi

              wt_path="$(git wt-feature-branch --print-path \
                --base "$(_wt_base)" "$@")" || return
              # direnv's chpwd hook evaluates .envrc on the cd; an untrusted one
              # loads nothing, so allow must precede the cd or the flake env never
              # reaches this shell. Idempotent on an already-trusted path.
              ${pkgs.direnv}/bin/direnv allow "$wt_path"
              cd "$wt_path" || return
            }

            # The agent's commits stay unsigned, so `git log --show-signature`
            # tells you what it wrote and `git adopt` is what claims it. pi
            # exports the same keys itself (pi-wrapper/wrapper.sh); this covers
            # the agents that do not. Scoped to $cmd, so your own commits in
            # the worktree afterwards sign normally.
            #
            # `--` separates wt's arguments from the agent's, and is consumed
            # here rather than forwarded: pi's sandbox wrapper reads `--` as
            # its own end-of-flags and would hand --allow-read to the real pi
            # binary, which rejects it.
            wtx() {
              if [[ $# -lt 2 ]]; then
                echo "usage: wtx <command> <ticket|name> [base] [-- <command args>]" >&2
                return 1
              fi
              local cmd="$1"
              shift
              local -a wt_args cmd_args
              while (( $# )); do
                [[ $1 == -- ]] && { shift; cmd_args=("$@"); break }
                wt_args+=("$1")
                shift
              done
              wt "''${wt_args[@]}" || return
              GIT_CONFIG_COUNT=2 \
                GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
                GIT_CONFIG_KEY_1=tag.gpgsign GIT_CONFIG_VALUE_1=false \
                "$cmd" "''${cmd_args[@]}"
            }

            wtc() { wtx claude "$@" }
            wtp() { wtx pi "$@" }
          ''
        ];
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

    # zsh-histdb shells out to sqlite3 and declares no dependency on it. macOS
    # carries one in the base system, so this is what the Linux hosts were
    # missing.
    home.packages = [ pkgs.sqlite ];
  };
}
