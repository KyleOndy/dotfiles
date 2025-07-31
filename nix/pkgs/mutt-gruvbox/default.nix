{
  lib,
  stdenv,
  fetchurl,
}:

stdenv.mkDerivation rec {
  pname = "mutt-gruvbox";
  version = "20220226";

  src = fetchGit {
    url = "https://git.sthu.org/repos/mutt-gruvbox.git";
    rev = "b0740a654686c549d09986db4adcfc6d0bed38bf";
  };

  #dontConfigure = true;
  #dontBuild = true;
  # This overrides the shell code that is run during the installPhase.
  # By default; this runs `make install`.
  # The install phase will fail if there is no makefile; so it is the
  # best choice to replace with our custom code.
  installPhase = ''
    mkdir -p $out/
    cp *.muttrc $out/
  '';

  meta = with lib; {
    description = "A gruvbox colorscheme for mutt and neomutt";
    homepage = "https://git.sthu.org/?p=mutt-gruvbox.git;a=summary";
    platforms = platforms.linux;
    #license = licenses.none;
  };
}
