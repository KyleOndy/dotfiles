# https://berkeleygraphics.com/
{
  lib,
  stdenv,
  file,
}:

stdenv.mkDerivation {
  pname = "berkeley-mono";
  version = "2.002";
  src = ./.;

  nativeBuildInputs = [ file ];

  installPhase = ''
    # make sure we have decrypted the font
    for font in *.otf; do
     ${file}/bin/file $font | grep --quiet 'OpenType font data'
    done

    mkdir -p $out/share/fonts/opentype/berkeley-mono
    cp -r *.otf $out/share/fonts/opentype/berkeley-mono

    runHook postInstall
  '';

  meta = with lib; {
    description = "Berkeley Mono Typeface";
    homepage = "https://berkeleygraphics.com/";
    license = licenses.unfree;
    platforms = platforms.all;
  };
}
