{
  lib,
  stdenv,
  fetchurl,
  pkgs,
}:

stdenv.mkDerivation {
  pname = "pxe-api";
  version = "20220226";

  src = ./.;
  #phases = [ "installPhase" ];

  installPhase = ''
    mkdir -p $out/bin
    cp pxe_api.py $out/bin/pxe-api
  '';
}
