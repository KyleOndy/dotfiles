{
  lib,
  stdenv,
  fetchgit,
}:

stdenv.mkDerivation rec {
  pname = "zsh-histdb";
  version = "20220118";

  src = fetchGit {
    url = "https://github.com/larkery/zsh-histdb";
    rev = "30797f0c50c31c8d8de32386970c5d480e5ab35d";
  };

  installPhase = ''
    mkdir -p $out/
    cp -r . $out/
  '';

  meta = with lib; {
    description = "A slightly better history for zsh ";
    homepage = "https://github.com/larkery/zsh-histdb";
    platforms = platforms.linux ++ platforms.darwin;
    license = licenses.mit;
  };
}
