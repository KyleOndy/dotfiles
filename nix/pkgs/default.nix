self: super: {
  babashka-scripts = super.callPackage ./babashka-scripts { };
  berkeley-mono = super.callPackage ./berkeley-mono { };
  concourse = super.callPackage ./concourse { };
  helios = super.callPackage ./helios { };
  mutt-colors-solarized = super.callPackage ./mutt-colors-solarized { };
  mutt-gruvbox = super.callPackage ./mutt-gruvbox { };
  my-scripts = super.callPackage ./my-scripts { };
  octo = super.callPackage ./octo { };
  pragmata-pro = super.callPackage ./pragmata-pro { };
  pxe-api = super.callPackage ./pxe-api { };
  tmux-gruvbox = super.callPackage ./tmux-gruvbox { };
  vscode-ls = super.callPackage ./vscode-ls { };
  zsh-histdb = super.callPackage ./zsh-histdb { };
}
