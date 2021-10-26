self: super: {
  my-scripts = super.callPackage ./my-scripts { };
  octo = super.callPackage ./octo { };
  zsh-vi-mode = super.callPackage ./zsh-vi-mode { };
}
