self: super: {
  ask = super.callPackage ./ask { };
  audio-language-check = super.callPackage ./audio-language-check { };
  babashka-scripts = super.callPackage ./babashka-scripts { };
  backup-photos = super.callPackage ./backup-photos { };
  berkeley-mono = super.callPackage ./berkeley-mono { };
  forge = super.callPackage ./forge { lima = self.master.lima; };
  fuji-transcode = super.callPackage ./fuji-transcode { };
  git-worktree-prompt = super.callPackage ./git-worktree-prompt { };
  helios = super.callPackage ./helios { };
  histdb-backup = super.callPackage ./histdb-backup { };
  instax-link = super.callPackage ./instax-link { };
  linear-cli = super.callPackage ./linear-cli { };
  my-scripts = super.callPackage ./my-scripts { };
  photos-fanout = super.callPackage ./photos-fanout { };
  photos-promote = super.callPackage ./photos-promote { };
  photos-recall = super.callPackage ./photos-recall { };
  pragmata-pro = super.callPackage ./pragmata-pro { };
  s3-archive-push = super.callPackage ./s3-archive-push { };
  s3-archive-reconcile = super.callPackage ./s3-archive-reconcile { };
  winnow = super.callPackage ./winnow { };
  kubectl-rexec = super.callPackage ./kubectl-rexec { };
  presence-debug = super.callPackage ./presence-debug { };
  pi-wrapper = super.callPackage ./pi-wrapper { inherit (self) llm-agents; };
  mcloud-pins = super.callPackage ./mcloud-pins { };
  search-mail = super.callPackage ./search-mail { };
  mlx = super.callPackage ./mlx { };
  tmux-status = super.callPackage ./tmux-status { };
}
