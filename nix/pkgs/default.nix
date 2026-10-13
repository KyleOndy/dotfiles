self: super: {
  ask = super.callPackage ./ask { inherit (self) mlx; };
  audio-language-check = super.callPackage ./audio-language-check { };
  babashka-scripts = super.callPackage ./babashka-scripts { };
  backup-git-repos = super.callPackage ./backup-git-repos { };
  backup-photos = super.callPackage ./backup-photos { };
  backup-resolve-projects = super.callPackage ./backup-resolve-projects { };
  berkeley-mono = super.callPackage ./berkeley-mono { };
  berkeley-mono-nerd-font = super.callPackage ./berkeley-mono-nerd-font { };
  birdnet-go = super.callPackage ./birdnet-go { };
  forge = super.callPackage ./forge { lima = self.master.lima; };
  git-worktree-prompt = super.callPackage ./git-worktree-prompt { };
  helios = super.callPackage ./helios { };
  histdb-backup = super.callPackage ./histdb-backup { };
  kagi = super.callPackage ./kagi { };
  linear-cli = super.callPackage ./linear-cli { };
  my-scripts = super.callPackage ./my-scripts { };
  notification-bell = super.callPackage ./notification-bell { };
  photos-promote = super.callPackage ./photos-promote { };
  photos-recall = super.callPackage ./photos-recall { };
  pragmata-pro = super.callPackage ./pragmata-pro { };
  s3-archive-push = super.callPackage ./s3-archive-push { };
  s3-archive-reconcile = super.callPackage ./s3-archive-reconcile { };
  secrets-check = super.callPackage ./secrets-check { };
  winnow = super.callPackage ./winnow { };
  kubectl-rexec = super.callPackage ./kubectl-rexec { };
  presence-debug = super.callPackage ./presence-debug { };
  alamode-runtime = super.callPackage ./alamode-runtime { inherit (self) llm-agents; };
  alamode-relay = super.callPackage ./alamode-relay { };
  alamode-builder = super.callPackage ./alamode-builder { };
  alamode = super.callPackage ./alamode {
    inherit (self)
      llm-agents
      alamode-runtime
      alamode-relay
      alamode-builder
      ;
  };
  alamode-coordinator = super.callPackage ./alamode-coordinator { inherit (self) forge; };
  alamode-delegate = super.callPackage ./alamode-delegate { };
  mcloud-pins = super.callPackage ./mcloud-pins { };
  mcloud-rank = super.callPackage ./mcloud-rank { };
  leak-guard = super.callPackage ./leak-guard { inherit (self) llm-agents; };
  alamode-seats = super.callPackage ./alamode-seats { };
  advisor-eval = super.callPackage ./advisor-eval { inherit (self) llm-agents; };
  search-mail = super.callPackage ./search-mail { };
  mail-stragglers = super.callPackage ./mail-stragglers { };
  mlx = super.callPackage ./mlx { };
  mysides = super.callPackage ./mysides { };
  tmux-status = super.callPackage ./tmux-status { };
}
