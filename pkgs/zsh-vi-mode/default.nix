# todo: contribute this back upstream to nixpkgs
{ stdenv, fetchFromGitHub }:

stdenv.mkDerivation rec {
  name = "zsh-vi-mode";
  version = "0.8.5";

  # fetchFromGitHub is a build support function that fetches a GitHub
  # repository and extracts into a directory; so we can use it
  # fetchFromGithub is actually a derivation itself :)
  src = fetchFromGitHub {
    owner = "jeffreytse";
    repo = "zsh-vi-mode";
    rev = "v${version}";
    sha256 = "EOYqHh0rcgoi26eopm6FTl81ehak5kXMmzNcnJDH8/E=";
  };

  # This overrides the shell code that is run during the installPhase.
  # By default; this runs `make install`.
  # The install phase will fail if there is no makefile; so it is the
  # best choice to replace with our custom code.
  installPhase = ''
    mkdir -p $out
    cp *.zsh $out/
  '';
}
