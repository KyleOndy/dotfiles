self: super: {
  babashka-scripts = super.callPackage ./babashka-scripts { };
  berkeley-mono = super.callPackage ./berkeley-mono { };
  concourse = super.callPackage ./concourse { };
  git-worktree-prompt = super.callPackage ./git-worktree-prompt { };
  helios = super.callPackage ./helios { };
  linear-cli = super.callPackage ./linear-cli { };
  mutt-colors-solarized = super.callPackage ./mutt-colors-solarized { };
  mutt-gruvbox = super.callPackage ./mutt-gruvbox { };
  my-scripts = super.callPackage ./my-scripts { };
  octo = super.callPackage ./octo { };
  pragmata-pro = super.callPackage ./pragmata-pro { };
  tmux-gruvbox = super.callPackage ./tmux-gruvbox { };
  vscode-ls = super.callPackage ./vscode-ls { };
  battery-draw = super.callPackage ./battery-draw { };
  bgutil-ytdlp-pot-server = super.callPackage ./bgutil-ytdlp-pot-server { };
  zsh-histdb = super.callPackage ./zsh-histdb { };
}
