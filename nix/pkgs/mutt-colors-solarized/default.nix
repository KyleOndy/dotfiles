{
  lib,
  stdenv,
  fetchurl,
}:
# this may exist somewhere else already package in NIX, just doing it myself
# out of convience since I only need one of the themes.

stdenv.mkDerivation rec {
  pname = "mutt-colors-solarized";
  version = "20220226";

  src = fetchGit {
    url = "https://github.com/altercation/solarized";
    rev = "62f656a02f93c5190a8753159e34b385588d5ff3";
  };

  installPhase = ''
    mkdir -p $out/
    cp ./mutt-colors-solarized/*.muttrc $out/
  '';

  meta = with lib; {
    description = "Solarized Colorscheme for Mutt";
    homepage = "https://github.com/altercation/solarized/tree/master/ ";
    platforms = platforms.unix; # Just text files, works on all Unix-like systems
    license = licenses.mit;
  };
}
