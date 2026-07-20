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
      rich
      shellingham
      typer
      typing-extensions
    ]
  );
in
stdenv.mkDerivation {
  pname = "helios";
  version = "20260720";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    mkdir -p $out/libexec/helios $out/bin
    cp *.py $out/libexec/helios/

    makeWrapper ${pythonEnv}/bin/python3 $out/bin/helios \
      --add-flags "$out/libexec/helios/main.py" \
      --prefix PATH : ${lib.makeBinPath [ pkgs.exiftool ]}
  '';

  meta = with lib; {
    description = "Hand-rolled photo import and dedup CLI";
    platforms = platforms.linux;
  };
}
