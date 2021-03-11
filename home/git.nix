{ pkgs, ... }:
let
  old_dots = import ./_dotfiles-dir.nix;

in
{
  programs.git = {
    enable = true;
    package = pkgs.gitAndTools.gitFull; # all the tools
    aliases = {
      # show all currently configured alias, sorted. Sometimes I forget what
      # I've configured.
      alias = "! git config --global --get-regexp ^alias | sort";
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
      # undo the last commit.
      undo = "reset HEAD~1 --mixed";
      # unstate all pending changes
      unstage = "reset HEAD";
      # status is _just_ too long to type.
      s = "status";
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
    userEmail = "kyle@ondy.org";
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
        # use "vimdiff", defined later at neovim
        tool = "vimdiff";
        # show prefix's during a diff that relate to the content being diffed. Helps
        # keep things straight in my head.
        mnemonicprefix = "true";
        # use the patience algorithm. A little slower, but more human readable
        # output.
        algorithm = "patience";
      };
      difftool = {
        # use "vimdiff", defined later
        tool = "vimdiff";
        # prompting before opening difftools is just one more key press getting in
        # the way of the groove.
        prompt = "false";
      };
      merge = {
        # --ff-only by default, force a command line flag to be thrown otherwise.
        # Keep the commits atomic and the history clean.
        ff = "only";
        # use "vimdiff", defined later
        tool = "vimdiff";
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
    };
  };
  xdg = {
    # todo: move this into home-manager configuration
    configFile."git/message.txt".source = old_dots + /git/message.txt;
  };

  home.packages = with pkgs;
    [
      gitAndTools.pre-commit # manage git precommit hooks
      git-lfs
    ];
}
