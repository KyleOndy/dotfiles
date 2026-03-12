{
  lib,
  stdenv,
  rustPlatform,
  darwin,
}:

rustPlatform.buildRustPackage {
  pname = "battery-draw";
  version = "0.1.0";

  src = ./.;

  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  buildInputs = lib.optionals stdenv.hostPlatform.isDarwin (
    with darwin.apple_sdk.frameworks;
    [
      IOKit
      CoreFoundation
    ]
  );

  meta = with lib; {
    description = "Fast battery power usage monitoring for tmux status bars";
    homepage = "https://github.com/kyleondy";
    license = licenses.mit;
    maintainers = with maintainers; [ kyleondy ];
    platforms = platforms.linux ++ platforms.darwin;
  };
}
