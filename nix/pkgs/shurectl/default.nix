{
  lib,
  rustPlatform,
  fetchFromGitHub,
}:

rustPlatform.buildRustPackage rec {
  pname = "shurectl";
  version = "2.14.2";

  src = fetchFromGitHub {
    owner = "Humblemonk";
    repo = "shurectl";
    rev = "v${version}";
    hash = "sha256-IVckQeGycFeQ91ag9nvFt+9X+4/CvveqGeUwUEaU3d4=";
  };

  cargoHash = "sha256-T04yE1PsUz/fybV2bvfAXEb60rxxdAg/qNhBDIxopfw=";

  meta = with lib; {
    description = "TUI and CLI configurator for Shure MOTIV USB interfaces and microphones";
    homepage = "https://github.com/Humblemonk/shurectl";
    license = licenses.gpl3Only;
    mainProgram = "shurectl";
  };
}
