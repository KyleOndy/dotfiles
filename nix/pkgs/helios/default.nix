{ lib, stdenv, fetchurl, pkgs }:

stdenv.mkDerivation {
  pname = "helios";
  version = "20240205";

  src = ./.;
  #phases = [ "installPhase" ];

  installPhase = ''
    mkdir -p $out/bin
    cp *.py $out/bin/
    cp main.py $out/bin/helios
  '';
}
