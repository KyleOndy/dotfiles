self: super: {
  concourse = super.callPackage ./concourse { };
  my-scripts = super.callPackage ./my-scripts { };
  octo = super.callPackage ./octo { };
  vscode-ls = super.callPackage ./vscode-ls { };
  zsh-vi-mode = super.callPackage ./zsh-vi-mode { };
}
