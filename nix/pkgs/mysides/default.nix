# nixpkgs repackages upstream's release .pkg, which holds only an x86_64
# binary, so without Rosetta it exits "bad CPU type in executable".
{
  lib,
  stdenv,
  fetchFromGitHub,
}:

stdenv.mkDerivation rec {
  pname = "mysides";
  version = "1.0.1";

  src = fetchFromGitHub {
    owner = "mosen";
    repo = "mysides";
    rev = "v${version}";
    hash = "sha256-1CdAwbkODnqZrK/adPwCVlg++fSD/00M/M1Lxk3cWi8=";
  };

  buildPhase = ''
    runHook preBuild
    $CC -fobjc-arc -Wno-deprecated-declarations \
      -framework Foundation -framework CoreServices \
      -o mysides src/main.m src/SharedFileList.m
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 mysides -t $out/bin
    runHook postInstall
  '';

  meta = with lib; {
    description = "Manage macOS Finder sidebar favorites";
    homepage = "https://github.com/mosen/mysides";
    license = licenses.mit;
    platforms = platforms.darwin;
    mainProgram = "mysides";
  };
}
