# https://fsd.it/shop/fonts/pragmatapro/
{ lib, stdenv, fetchurl, pkgs }:

pkgs.stdenv.mkDerivation {
  pname = "pragmata-pro";
  version = "0.9";
  src = ./.;

  installPhase = ''
    # make sure we have decrypted the font
    for font in *.otf; do
     file $font | grep --quiet 'OpenType font data'
    done

    mkdir -p $out/share/fonts/opentype/pragmata-pro
    cp -r *.otf $out/share/fonts/opentype/pragmata-pro

    runHook postInstall
  '';
}
