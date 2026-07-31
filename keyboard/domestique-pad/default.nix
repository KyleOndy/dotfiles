{
  lib,
  stdenv,
  fetchFromGitHub,
  gcc-arm-embedded,
  python3,
  which,
  gnumake,
  qmk,
}:

let
  # Same rev as keyboard/ergodox, so nix fetches the tree once. Pinned
  # separately on purpose: bumping one board's QMK must not move the other's.
  qmk-firmware = fetchFromGitHub {
    owner = "qmk";
    repo = "qmk_firmware";
    rev = "0.27.3";
    hash = "sha256-ifiv5vd3ZyMidWMMIvCDOh4vM9AsnnHR29rj9D64PVk=";
    fetchSubmodules = true;
  };
in
stdenv.mkDerivation {
  pname = "domestique-pad";
  version = "0.0.1";

  src = qmk-firmware;

  nativeBuildInputs = [
    gcc-arm-embedded
    python3
    which
    gnumake
    qmk
  ];

  postPatch = ''
    mkdir -p keyboards/domestique_pad/keymaps/default
    cp ${./keyboard.json} keyboards/domestique_pad/keyboard.json
    cp ${./config.h} keyboards/domestique_pad/config.h
    cp ${./keymap.c} keyboards/domestique_pad/keymaps/default/keymap.c
  '';

  buildPhase = ''
    runHook preBuild

    # make rather than the qmk CLI, which wants a git checkout it does not have
    # here.
    make domestique_pad:default

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    # RP2040 takes a uf2 over mass storage; there is no flasher binary in the
    # loop, so this file is the whole deliverable.
    cp domestique_pad_default.uf2 $out/

    runHook postInstall
  '';

  meta = {
    description = "QMK firmware for the domestique push-to-talk pad (Adafruit KB2040)";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}
