{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.dev.git;
in
{
  options.hmFoundry.dev.git = {
    enable = mkEnableOption "todo";
    userEmail = mkOption {
      type = types.str;
      default = "kyle@ondy.org"; # TODO: remove default and set explicitly
      description = "Default email set in git config.";
    };
  };

  config = mkIf cfg.enable {
    programs.git = {
      enable = true;
      package = pkgs.gitAndTools.gitFull; # all the tools
      aliases = {
        # Sometimes I forget what I've configured. Show all currently configured
        # alias, sorted. To make it a bit prettier I output this in column
        # format, abusing the `#` character assuming the octothorpe will not
        # appear in my alias.
        alias = "! git config --get-regexp ^alias | sed 's/alias\.//'  | sed 's/ /#/' | column -s'#' -t";
        # patch add. Easiest way to keep commits small.
        ap = "add -p";
        # track file, effectively staging the file without any content
        track = "add -N";
        # easy way to open commit in $EDITOR
        cm = "commit";
        # reword the last commit
        reword = "commit --amend";
        # add staged changes to last commit, keeping that message
        forgot = "commit --amend -C HEAD";
        # quickly create a commit with a message on the command line.
        cmm = "commit -m";
        # show to root directory of the git repo
        root = "rev-parse --show-toplevel";
        # show diff with words highlighted.
        wdiff = "diff --color-words";
        # quickly checkout a branch.
        co = "checkout";
        # quickly checkout a new branch from current HEAD
        cob = "checkout -b";
        # see what is currently staged
        cdiff = "diff --cached";
        # undo the last commit.
        undo = "reset HEAD~1 --mixed";
        # unstate all pending changes
        unstage = "reset HEAD";
        # status is _just_ too long to type.
        s = "status";
        # same with fetch
        f = "fetch";

        # show what files are ignored by the .gitignore
        ignored = "ls-files . --ignored --exclude-standard --others";
        # show what files are currently untracked
        untracked = "ls-files . --exclude-standard --others";
        # a hacky, and not gaurented way, to print the url of the webui of a repo.
        url = "! git config remote.origin.url | cut -d@ -f2 | tr : /";
        # edit all files that are changed in the current working directory.
        edit = "! $EDITOR $(git diff --name-only)";
        # list all local branches, sorted by last commit date.
        recent = "branch --verbose --sort=-committerdate";
        # pull down latest changes and rebase against default origin. This is run
        # before starting any work on a branch.
        sync = "! git fetch --all --prune; git rebase --rebase-merges --autostash && git status";
        # add everything to a commit to comeback to later
        wip = "! git add -A && git commit -m 'WIP: savepoint via alias.' -m 'No pre-commit hooks have been run' --no-verify --no-gpg-sign";
        # like wip, but probably not coming back, reset to last commit too.
        ditch = "! git add -A && git commit -m 'TMP: Save before clean reset' && git reset HEAD~1 --hard";
        # show the upstream
        upstream = "rev-parse --abbrev-ref --symbolic-full-name @{upstream}";
        # Delete the remote version of the current branch
        unpublish = "! git push origin :$(git branch-name)";
        # get info from the git log
        lg = "log --graph --pretty=format:'%Cred%h%Creset -%G?-%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset'";
        # Grep the log
        loggrep = "log -E -i --grep";
        # when gpg-agent crashes on me, I can recover the commit with this alias. I
        # _feel_ like there should be a better way to handle this, but it is better
        # than nothing. This is set as a shell command so no matter how deep we are
        # in the tree of this repository, the command is executed at the root on the
        # repo so our file path is always correct.
        fix-commit = "! git commit --edit --file=.git/COMMIT_EDITMSG";
        # easily follow the history of a single file
        file-history = "log -p -M --follow --stat";
        # non-interactively apply the current staged files to a ref
        amend-to = "! f() { git commit --fixup \"$1\" && GIT_SEQUENCE_EDITOR=true git rebase --interactive --autosquash \"$1^\";}; f";
      };
      delta = {
        enable = true;
      };
      signing = {
        # signed commits don't _really_ help, because no one will ever verify
        # them, but they give a fancy 'verified' badge in gitlab and github.
        key = "DB0E3C33491F91C9"; # pragma: allowlist secret
        signByDefault = true;
      };
      userEmail = cfg.userEmail;
      userName = "Kyle Ondy";

      # things that home-manager doesn't explictly handle
      extraConfig = {
        core = {
          # updates to any <ref> are logged in $GIT_DIR/logs/<refs>. This information
          # can be used to determine the state of a repository at a point in history.
          logAllRefUpdates = "always";
        };
        interactive = {
          # when in --patch mode, take your input without having to hit enter. Greatly
          # speeds up the workflow.
          # NOTE: this requires that perl module `Term:ReadKey` is available.
          singleKey = "true";
        };
        commit = {
          # template containing useful directions for writing pertinent and helpful
          # commit messages.
          template = "~/.config/git/message.txt";
          # adding commit details to the commit message editor makes it much easier to
          # write good commit messages, along with giving convenient autocomplete
          # relating to the content of the commit.
          verbose = "true";
        };
        init = {
          # there is nothing of value in the template yet, but having the template
          # wired up lowers the friction when I'd like to add something.
          templatedir = "~/.config/git/template";
          # trying to do my part in using appropaite termonogly
          defaultBranch = "main";
        };
        submodule = {
          # recurse into submodules by default.
          recurse = "true";
        };
        status = {
          # show the number of stashes at the bottom of the status message.
          showStash = "true";
        };
        color = {
          # let git decide when to be colorful.
          ui = "auto";
        };
        diff = {
          # use "nvimdiff", defined later at neovim
          tool = "nvimdiff";
          # show prefix's during a diff that relate to the content being diffed. Helps
          # keep things straight in my head.
          mnemonicprefix = "true";
          # use the patience algorithm. A little slower, but more human readable
          # output.
          algorithm = "patience";
        };
        difftool = {
          # use "nvimdiff", defined later
          tool = "nvimdiff";
          # prompting before opening difftools is just one more key press getting in
          # the way of the groove.
          prompt = "false";
        };
        mergetool = {
          # prompting before opening difftools is just one more key press getting in
          # the way of the groove.
          prompt = "false";
          nvimdiff = {
            cmd = "nvim -d \"$BASE\" \"$LOCAL\" \"$REMOTE\" \"$MERGED\" -c 'wincmd w' -c 'wincmd J'";
          };
        };
        merge = {
          # --ff-only by default, force a command line flag to be thrown otherwise.
          # Keep the commits atomic and the history clean.
          ff = "only";
          # use "nvimdiff", defined later
          tool = "nvimdiff";
          # add branch description to merge commits
          branchdesc = "true";
          # add additional git log information to merge commit.
          log = "true";
          # show unmodified (original) copy of conflict along with the conflicted
          # version.
          conflictstyle = "diff3";
          # do not litter my working directry with *.orig files.
          keepBackup = "false";
        };
        push = {
          # makes pushing to remotes a bit easier, not having to specify the branch
          # name if the remote has a matching name.
          default = "current";
          # push the local tags to the remote automagically.
          followTags = "true";
          # not all remotes support signed pushes. This setting should ask the remote
          # if they are supported, and respect the remote's wishes.
          gpgSign = "if-asked";
        };
        pull = {
          # rebase when pulling, avoid merge commits at all costs.
          rebase = "true";
        };
        rebase = {
          # stash any pending changes in the work directory when rebaseing, and apply
          # them when done. This can cause some strange merge conflict to be resolved
          # locally, but the convince is worth it.
          autoStash = "true";
          # show a diffstat of what changed since last rebase. Useful to keep track of
          # things that are changing upstream.
          stat = "true";
        };
        fetch = {
          # prune automatically on fetches.
          prune = "true";
          # prune tags additionally when fetching.
          pruneTags = "true";
        };
        credential = {
          helper = "store";
        };
        advice = {
          skippedCherryPicks = "false";
        };
      };
    };
    xdg = {
      # todo: move this into home-manager configuration
      configFile."git/message.txt".text = ''
        # <type>: (If applied, this commit will...) <subject> (Max 50 char)
        # |<----  Using a Maximum Of 50 Characters  ---->|


        # Explain why this change is being made
        # |<----   Try To Limit Each Line to a Maximum Of 72 Characters   ---->|

        # Provide links or keys to any relevant tickets, articles or other resources
        # Example: Github issue #23

        # --- COMMIT END ---
        # Type can be
        #    build    (Changes that affect the build system or external dependencies)
        #    chore    (Other changes that don't modify src or test files)
        #    ci       (Changes to our CI configuration files and scripts)
        #    config   (A change to configuration values)
        #    docs     (Documentation only changes)
        #    feat     (A new feature)
        #    fix      (A bug fix)
        #    perf     (A code change that improves performance)
        #    refactor (A code change that neither fixes a bug nor adds a feature)
        #    revert   (Reverts a previous commit)
        #    style    (Changes that do not affect the meaning of the code (white-space, etc)
        #    test     (Adding missing tests or correcting existing tests)
        # --------------------
        # Remember to
        #    Capitalize the subject line
        #    Use the imperative mood in the subject line
        #    Do not end the subject line with a period
        #    Separate subject from body with a blank line
        #    Use the body to explain what and why vs. how
        #    Can use multiple lines with "-" for bullet points in body
        # --------------------
        # For more information about this template, check out
        # https://gist.github.com/adeekshith/cd4c95a064977cdc6c50
        # --------------------
        # For more information about commit types, check out
        # https://www.conventionalcommits.org/en/v1.0.0/
      '';
    };

    home.packages = with pkgs;
      [
        git-crypt
        git-lfs
        gitAndTools.pre-commit # manage git precommit hooks
      ];
  };
}
