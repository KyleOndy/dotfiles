# todo: contribute this back upstream to nixpkgs
self: super: {

  zsh-vi-mode = with self; stdenv.mkDerivation {
    name = "zsh-vi-mode";

    # fetchFromGitHub is a build support function that fetches a GitHub
    # repository and extracts into a directory; so we can use it
    # fetchFromGithub is actually a derivation itself :)
    src = fetchFromGitHub {
      owner = "jeffreytse";
      repo = "zsh-vi-mode";
      rev = "b612d16b0873917a034076793914ade9b4ef3635";
      sha256 = "tlAgsIHHZPnk6NznOdzvLHlB1J2FkwCuGLlGHzR06Jg=";
    };

    # This overrides the shell code that is run during the installPhase.
    # By default; this runs `make install`.
    # The install phase will fail if there is no makefile; so it is the
    # best choice to replace with our custom code.
    installPhase = ''
      mkdir -p $out
      cp *.zsh $out/
    '';
  };
}

