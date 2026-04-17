{
  lib,
  buildGoModule,
  makeWrapper,
  bubblewrap,
}:

buildGoModule {
  pname = "agent-sandbox";
  version = "0.1.0";

  src = ./.;

  # stdlib only — no external dependencies, no vendor directory.
  vendorHash = null;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/agent-sandbox \
      --set AGENT_SANDBOX_BWRAP ${bubblewrap}/bin/bwrap
  '';

  meta = with lib; {
    description = "Framework-agnostic agent process sandbox";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
    platforms = platforms.linux;
  };
}
