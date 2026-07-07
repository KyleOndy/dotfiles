# InstaxLink.py vendored from https://github.com/paorin/InstaxLink
# commit b66f40f9e2b3f529535b4cf8593e3e23da9ea76f (2025-02-09)
# Reverse-engineered BLE client for the Fujifilm Instax Link WIDE printer;
# no official Linux driver exists.
#
# instax_print.py is Kyle's own wrapper: auto-resizes or interactively
# crops an arbitrary image to the Wide Link's required 1260x840, then
# shells out to instax-link to send it.
{
  lib,
  stdenv,
  pkgs,
  makeWrapper,
}:

let
  pythonEnv = pkgs.python3.withPackages (
    pythonPackages: with pythonPackages; [
      bleak
      pybluez
      pillow
      tkinter
    ]
  );
in
stdenv.mkDerivation {
  pname = "instax-link";
  version = "unstable-2025-02-09";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/libexec/instax-link $out/bin
    cp InstaxLink.py instax_print.py $out/libexec/instax-link/

    makeWrapper ${pythonEnv}/bin/python3 $out/bin/instax-link \
      --add-flags "$out/libexec/instax-link/InstaxLink.py"

    makeWrapper ${pythonEnv}/bin/python3 $out/bin/instax-print \
      --add-flags "$out/libexec/instax-link/instax_print.py" \
      --prefix PATH : $out/bin
  '';

  meta = with lib; {
    description = "Crop/resize and print JPEGs to a Fujifilm Instax Link WIDE printer over Bluetooth LE";
    homepage = "https://github.com/paorin/InstaxLink";
    license = licenses.gpl3Only;
    platforms = platforms.linux;
  };
}
