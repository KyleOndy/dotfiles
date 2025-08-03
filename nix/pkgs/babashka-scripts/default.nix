# Babashka scripts package using the custom builder
{
  lib,
  stdenv,
  pkgs,
  babashka,
  ffmpeg,
}:

let
  buildBabashkaScripts = import ./babashka-builder.nix {
    inherit lib stdenv babashka;
  };
in

buildBabashkaScripts {
  pname = "babashka-scripts";
  version = "20250203";

  src = ./.;

  buildInputs = [
    ffmpeg # Required for media processing scripts
  ];

  meta = with lib; {
    description = "Kyle Ondy's babashka scripts";
    homepage = "https://github.com/kyleondy";
    license = licenses.mit;
    maintainers = with maintainers; [ kyleondy ];
    platforms = platforms.linux ++ platforms.darwin;
  };
}
