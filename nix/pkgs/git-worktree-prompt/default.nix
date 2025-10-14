{
  lib,
  rustPlatform,
  git,
}:

rustPlatform.buildRustPackage {
  pname = "git-worktree-prompt";
  version = "0.1.0";

  src = ./.;

  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  nativeBuildInputs = [
    git
  ];

  meta = with lib; {
    description = "Fast git prompt with worktree support for Starship";
    homepage = "https://github.com/kyleondy";
    license = licenses.mit;
    maintainers = with maintainers; [ kyleondy ];
    platforms = platforms.linux;
  };
}
