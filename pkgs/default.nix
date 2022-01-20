self: super: {
  concourse = super.callPackage ./concourse { };
  mutt-gruvbox = super.callPackage ./mutt-gruvbox { };
  mutt-colors-solarized = super.callPackage ./mutt-colors-solarized { };
  my-scripts = super.callPackage ./my-scripts { };
  octo = super.callPackage ./octo { };
  vscode-ls = super.callPackage ./vscode-ls { };
}
