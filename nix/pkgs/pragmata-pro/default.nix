# https://fsd.it/shop/fonts/pragmatapro/
{
  lib,
  stdenv,
  file,
}:

stdenv.mkDerivation {
  pname = "pragmata-pro";
  version = "0.9";
  src = ./.;

  nativeBuildInputs = [ file ];

  installPhase = ''
    # make sure we have decrypted the font
    for font in *.otf; do
     ${file}/bin/file $font | grep --quiet 'OpenType font data'
    done

    mkdir -p $out/share/fonts/opentype/pragmata-pro
    cp -r *.otf $out/share/fonts/opentype/pragmata-pro

    runHook postInstall
  '';

  meta = with lib; {
    description = "PragmataPro Typeface";
    homepage = "https://fsd.it/shop/fonts/pragmatapro/";
    license = licenses.unfree;
    platforms = platforms.all;
  };
}
