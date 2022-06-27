self: super: {
  concourse = super.callPackage ./concourse { };
  mutt-gruvbox = super.callPackage ./mutt-gruvbox { };
  mutt-colors-solarized = super.callPackage ./mutt-colors-solarized { };
  my-scripts = super.callPackage ./my-scripts { };
  octo = super.callPackage ./octo { };
  pxe-api = super.callPackage ./pxe-api { };
  vscode-ls = super.callPackage ./vscode-ls { };
}
