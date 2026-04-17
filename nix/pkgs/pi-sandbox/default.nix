{
  lib,
  buildGoModule,
  makeWrapper,
  agent-sandbox,
  ollama,
}:

buildGoModule {
  pname = "pi-sandbox";
  version = "0.1.0";

  src = ./.;

  vendorHash = "sha256-KTzxPnXE4vvPy20h72AayzKM1gHpag5VKtsjiFtB/6o=";

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/pi-sandbox \
      --prefix PATH : ${
        lib.makeBinPath [
          agent-sandbox
          ollama
        ]
      }
  '';

  meta = with lib; {
    description = "Run pi coding agent inside agent-sandbox with local ollama";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
