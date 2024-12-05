{ lib, stdenv, fetchFromGitHub, pkgs }:

stdenv.mkDerivation rec {
  pname = "tmux-gruvbox";
  version = "2.0.0";

  src = fetchFromGitHub {
    owner = "egel";
    repo = "tmux-gruvbox";
    rev = "v${version}";
    hash = "sha256-ol8CKXzxpki8+AFgPZoAXIrShSCcM7T+YB33jJTMEig=";
  };

  #unpackPhaes = "";
  #configurePhase = "";
  #
  nativeBuildInputs = with pkgs; [
    shellcheck
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/
    cp -r gruvbox-tpm.tmux src/ $out
    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Gruvbox color scheme for Tmux";
    homepage = https://github.com/egel/tmux-gruvbox;
    license = licenses.gpl3;
    maintainers = with maintainers; [ kyleondy ];
    platforms = platforms.linux ++ platforms.darwin;
  };
}
