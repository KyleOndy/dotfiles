{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "system-mem";
  version = "0.1.0";

  src = ./.;

  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  meta = with lib; {
    description = "Fast memory headroom monitoring for tmux status bars";
    homepage = "https://github.com/kyleondy";
    license = licenses.mit;
    maintainers = with maintainers; [ kyleondy ];
    platforms = platforms.linux ++ platforms.darwin;
  };
}
