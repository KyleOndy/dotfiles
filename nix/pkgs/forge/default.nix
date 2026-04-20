{
  lib,
  buildGoModule,
  installShellFiles,
}:

buildGoModule {
  pname = "forge";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: type:
      let
        rel = lib.removePrefix (toString ./. + "/") path;
      in
      !(builtins.elem rel [
        "default.nix"
        "result"
      ]);
  };

  vendorHash = null;

  subPackages = [ "." ];

  ldflags = [
    "-s"
    "-w"
    "-X main.version=0.1.0"
  ];

  nativeBuildInputs = [ installShellFiles ];

  postInstall = ''
    installShellCompletion --cmd forge \
      --bash <($out/bin/forge completion bash) \
      --zsh  <($out/bin/forge completion zsh)  \
      --fish <($out/bin/forge completion fish)
  '';

  meta = with lib; {
    description = "Personal SRE + dev orchestrator (forge flux drives the agent loop)";
    homepage = "https://github.com/kyleondy/dotfiles";
    license = licenses.mit;
    maintainers = with maintainers; [ kyleondy ];
    platforms = platforms.linux ++ platforms.darwin;
    mainProgram = "forge";
  };
}
