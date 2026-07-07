# Vendored from https://github.com/paorin/InstaxLink
# commit b66f40f9e2b3f529535b4cf8593e3e23da9ea76f (2025-02-09)
# Reverse-engineered BLE client for the Fujifilm Instax Link WIDE printer;
# no official Linux driver exists.
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
    cp InstaxLink.py $out/libexec/instax-link/
    makeWrapper ${pythonEnv}/bin/python3 $out/bin/instax-link \
      --add-flags "$out/libexec/instax-link/InstaxLink.py"
  '';

  meta = with lib; {
    description = "Print JPEGs to a Fujifilm Instax Link WIDE printer over Bluetooth LE";
    homepage = "https://github.com/paorin/InstaxLink";
    license = licenses.gpl3Only;
    platforms = platforms.linux;
  };
}
