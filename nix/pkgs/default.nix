{
  rev ? "unknown",
  buildDate ? "unknown",
}:
self: super: {
  ask = super.callPackage ./ask { };
  babashka-scripts = super.callPackage ./babashka-scripts { };
  backup-photos = super.callPackage ./backup-photos { };
  berkeley-mono = super.callPackage ./berkeley-mono { };
  concourse = super.callPackage ./concourse { };
  fuji-transcode = super.callPackage ./fuji-transcode { };
  git-worktree-prompt = super.callPackage ./git-worktree-prompt { };
  helios = super.callPackage ./helios { };
  instax-link = super.callPackage ./instax-link { };
  linear-cli = super.callPackage ./linear-cli { };
  mutt-colors-solarized = super.callPackage ./mutt-colors-solarized { };
  mutt-gruvbox = super.callPackage ./mutt-gruvbox { };
  my-scripts = super.callPackage ./my-scripts { };
  octo = super.callPackage ./octo { };
  photos-fanout = super.callPackage ./photos-fanout { };
  photos-promote = super.callPackage ./photos-promote { };
  photos-recall = super.callPackage ./photos-recall { };
  pragmata-pro = super.callPackage ./pragmata-pro { };
  tmux-gruvbox = super.callPackage ./tmux-gruvbox { };
  vscode-ls = super.callPackage ./vscode-ls { };
  winnow = super.callPackage ./winnow { };
  battery-draw = super.callPackage ./battery-draw { };
  bgutil-ytdlp-pot-server = super.callPackage ./bgutil-ytdlp-pot-server { };
  flutter-pi = super.callPackage ./flutter-pi { };
  kubectl-rexec = super.callPackage ./kubectl-rexec { };
  zsh-histdb = super.callPackage ./zsh-histdb { };
  presence-debug = super.callPackage ./presence-debug { };
  pi-wrapper = super.callPackage ./pi-wrapper { inherit (self) llm-agents; };
  pi-overnight = super.callPackage ./pi-overnight { };
}
