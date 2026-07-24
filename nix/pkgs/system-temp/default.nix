{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "system-temp";
  version = "0.1.0";

  src = ./.;

  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  meta = with lib; {
    description = "Fast CPU/GPU die temperature monitoring for tmux status bars";
    homepage = "https://github.com/kyleondy";
    license = licenses.mit;
    maintainers = with maintainers; [ kyleondy ];
    platforms = platforms.linux ++ platforms.darwin;
  };
}
