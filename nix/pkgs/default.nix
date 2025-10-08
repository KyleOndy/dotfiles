self: super: {
  babashka-scripts = super.callPackage ./babashka-scripts { };
  concourse = super.callPackage ./concourse { };
  helios = super.callPackage ./helios { };
  mutt-colors-solarized = super.callPackage ./mutt-colors-solarized { };
  mutt-gruvbox = super.callPackage ./mutt-gruvbox { };
  my-scripts = super.callPackage ./my-scripts { };
  octo = super.callPackage ./octo { };
  tmux-gruvbox = super.callPackage ./tmux-gruvbox { };
  vscode-ls = super.callPackage ./vscode-ls { };
  zsh-histdb = super.callPackage ./zsh-histdb { };
}
