{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule rec {
  pname = "kubectl-rexec";
  version = "0.1.9";

  src = fetchFromGitHub {
    owner = "adyen";
    repo = "kubectl-rexec";
    rev = "v${version}";
    hash = "sha256-76kOlpJuf7m8E0rxJRP+3dM+f+4AabYMP0aXp3Iusl4=";
  };

  vendorHash = "sha256-DBYl5ViEYco+Y1uD0Eg5SeqYHtbLg4szV3M8dttn7xo=";

  meta = with lib; {
    description = "kubectl plugin for audited exec/cp via a proxy sidecar";
    homepage = "https://github.com/adyen/kubectl-rexec";
    license = licenses.asl20;
    mainProgram = "kubectl-rexec";
  };
}
