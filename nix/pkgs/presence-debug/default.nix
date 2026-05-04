{ lib, stdenv }:

stdenv.mkDerivation {
  pname = "presence-debug";
  version = "1.0.0";

  src = ./.;

  buildPhase = ''
    $CC -O2 -Wall -Wextra -o presence-debug presence-debug.c
  '';

  installPhase = ''
    install -Dm755 presence-debug $out/bin/presence-debug
  '';

  meta = {
    description = "Debug tool for SEN0557 presence sensor (GPIO17 + /dev/ttyAMA3)";
    platforms = [ "aarch64-linux" ];
    mainProgram = "presence-debug";
  };
}
