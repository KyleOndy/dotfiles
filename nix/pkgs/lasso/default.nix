{
  lib,
  stdenv,
  makeWrapper,
  colima,
  kubectl,
  kubeconform,
  coreutils,
  jq,
}:
stdenv.mkDerivation {
  pname = "lasso";
  version = "0.1.0";
  src = ./.;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    mkdir -p $out/bin
    cp lasso.sh $out/bin/lasso
    chmod +x $out/bin/lasso
    wrapProgram $out/bin/lasso \
      --prefix PATH : ${
        lib.makeBinPath [
          colima
          kubectl
          kubeconform
          coreutils
          jq
        ]
      }
  '';
  meta = {
    description = "K8s Ralph Loop harness — invoke Claude Code until all checks pass";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    mainProgram = "lasso";
  };
}
