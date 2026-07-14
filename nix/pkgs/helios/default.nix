{
  lib,
  stdenv,
  pkgs,
  makeWrapper,
}:

let
  pythonEnv = pkgs.python3.withPackages (
    pythonPackages: with pythonPackages; [
      colorama
      gphoto2
      pillow
      pyusb
      pyyaml
      shellingham
      typer
      typing-extensions
    ]
  );
in
stdenv.mkDerivation {
  pname = "helios";
  version = "20260714";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    mkdir -p $out/libexec/helios $out/bin
    cp *.py $out/libexec/helios/

    makeWrapper ${pythonEnv}/bin/python3 $out/bin/helios \
      --add-flags "$out/libexec/helios/main.py"
  '';

  meta = with lib; {
    description = "Hand-rolled photo import and dedup CLI";
    platforms = platforms.linux;
  };
}
