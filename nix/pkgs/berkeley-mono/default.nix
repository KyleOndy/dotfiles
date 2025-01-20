# https://berkeleygraphics.com/
{ lib, stdenv, fetchurl, pkgs }:

pkgs.stdenv.mkDerivation {
  pname = "berkeley-mono";
  version = "2.002";
  src = ./.;

  installPhase = ''
    # make sure we have decrypted the font
    for font in *.otf; do
     file $font | grep --quiet 'OpenType font data'
    done

    mkdir -p $out/share/fonts/opentype/berkeley-mono
    cp -r *.otf $out/share/fonts/opentype/berkeley-mono

    runHook postInstall
  '';
}
