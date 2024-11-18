self: super: {
  berkeley-mono = super.callPackage ./berkeley-mono { };
  concourse = super.callPackage ./concourse { };
  helios = super.callPackage ./helios { };
  mutt-colors-solarized = super.callPackage ./mutt-colors-solarized { };
  mutt-gruvbox = super.callPackage ./mutt-gruvbox { };
  my-scripts = super.callPackage ./my-scripts { };
  octo = super.callPackage ./octo { };
  pxe-api = super.callPackage ./pxe-api { };
  vscode-ls = super.callPackage ./vscode-ls { };
  zsh-histdb = super.callPackage ./zsh-histdb { };
}
