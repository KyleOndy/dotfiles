{ lib, stdenv, fetchurl, pkgs }:

stdenv.mkDerivation {
  pname = "helios";
  version = "20240205";

  propagatedBuildInputs = [
    (pkgs.python3.withPackages (pythonPackages: with pythonPackages; [
      colorama
      flake8
      gphoto2
      pillow
      pytest
      shellingham
      typer
    ]))
  ];
  nativeBuildInputs = with pkgs; [
  ];

  src = ./.;
  #phases = [ "installPhase" ];

  installPhase = ''
    mkdir -p $out/bin
    cp *.py $out/bin/
    mv $out/bin/main.py $out/bin/helios
  '';
}
