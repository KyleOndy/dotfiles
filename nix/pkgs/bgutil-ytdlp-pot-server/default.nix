{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  pkg-config,
  python3,
  cairo,
  pango,
  libjpeg,
  giflib,
  librsvg,
  pixman,
  libpng,
  makeWrapper,
  nodejs_20,
}:

buildNpmPackage rec {
  pname = "bgutil-ytdlp-pot-server";
  version = "1.3.0";

  src = fetchFromGitHub {
    owner = "Brainicism";
    repo = "bgutil-ytdlp-pot-provider";
    rev = version;
    hash = "sha256-WPLNjfVYDbPsEMVhjuF3dVarahdIKT7pt518SePfB8A=";
  };

  # Build from the server/ subdirectory which contains package.json and package-lock.json
  sourceRoot = "${src.name}/server";

  # Hash of server/package-lock.json deps (computed with prefetch-npm-deps)
  npmDepsHash = "sha256-Qwwi6W+Oeu6ZeLmZP5vEfAKOJyivbULR5mlk7tcVIE8=";

  nodejs = nodejs_20;

  nativeBuildInputs = [
    pkg-config
    python3
    makeWrapper
  ];

  # canvas native addon requires these libraries at build time
  buildInputs = [
    cairo
    pango
    libjpeg
    giflib
    librsvg
    pixman
    libpng
  ];

  buildPhase = ''
    runHook preBuild
    node_modules/.bin/tsc
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/bgutil-pot-server
    npm prune --omit=dev
    cp -r build node_modules package.json $out/lib/bgutil-pot-server/
    makeWrapper ${lib.getExe nodejs_20} $out/bin/bgutil-ytdlp-pot-server \
      --add-flags "$out/lib/bgutil-pot-server/build/main.js"
    runHook postInstall
  '';

  meta = with lib; {
    description = "PO token provider HTTP server for yt-dlp bot detection bypass";
    homepage = "https://github.com/Brainicism/bgutil-ytdlp-pot-provider";
    license = licenses.gpl3Only;
    platforms = platforms.linux;
    mainProgram = "bgutil-ytdlp-pot-server";
  };
}
