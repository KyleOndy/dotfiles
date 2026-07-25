self: super: {
  ask = super.callPackage ./ask { };
  babashka-scripts = super.callPackage ./babashka-scripts { };
  backup-photos = super.callPackage ./backup-photos { };
  berkeley-mono = super.callPackage ./berkeley-mono { };
  fuji-transcode = super.callPackage ./fuji-transcode { };
  git-worktree-prompt = super.callPackage ./git-worktree-prompt { };
  helios = super.callPackage ./helios { };
  instax-link = super.callPackage ./instax-link { };
  linear-cli = super.callPackage ./linear-cli { };
  my-scripts = super.callPackage ./my-scripts { };
  photos-fanout = super.callPackage ./photos-fanout { };
  photos-promote = super.callPackage ./photos-promote { };
  photos-recall = super.callPackage ./photos-recall { };
  pragmata-pro = super.callPackage ./pragmata-pro { };
  winnow = super.callPackage ./winnow { };
  bgutil-ytdlp-pot-server = super.callPackage ./bgutil-ytdlp-pot-server { };
  kubectl-rexec = super.callPackage ./kubectl-rexec { };
  presence-debug = super.callPackage ./presence-debug { };
  pi-wrapper = super.callPackage ./pi-wrapper { inherit (self) llm-agents; };
  pi-overnight = super.callPackage ./pi-overnight { };
  search-mail = super.callPackage ./search-mail { };
  mlx = super.callPackage ./mlx { };
  tmux-status = super.callPackage ./tmux-status { };
}
