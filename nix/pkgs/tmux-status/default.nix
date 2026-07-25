{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "tmux-status";
  version = "0.1.0";

  src = ./.;

  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  meta = with lib; {
    description = "Status bar segments for tmux: battery, GPU, load, memory, temperature";
    homepage = "https://github.com/kyleondy";
    license = licenses.mit;
    maintainers = with maintainers; [ kyleondy ];
    platforms = platforms.linux ++ platforms.darwin;
  };
}
