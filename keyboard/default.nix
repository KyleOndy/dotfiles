{
  lib,
  stdenv,
  fetchFromGitHub,
  # AVR toolchain
  pkgsCross,
  python3,
  which,
  gnumake,
  qmk,
}:

let
  # Fetch QMK firmware with submodules
  qmk-firmware = fetchFromGitHub {
    owner = "qmk";
    repo = "qmk_firmware";
    rev = "0.27.3";
    hash = "sha256-ifiv5vd3ZyMidWMMIvCDOh4vM9AsnnHR29rj9D64PVk=";
    fetchSubmodules = true;
  };

  # AVR cross-compilation toolchain
  avr = pkgsCross.avr.buildPackages;
in
stdenv.mkDerivation {
  pname = "ergodox-ez-kyleondy";
  version = "1.0.0";

  src = qmk-firmware;

  nativeBuildInputs = [
    avr.gcc
    avr.binutils
    avr.avrdude
    python3
    python3.pkgs.pip
    which
    gnumake
    qmk
  ];

  postPatch = ''
    # Copy keymap into QMK tree
    mkdir -p keyboards/ergodox_ez/keymaps/kyleondy
    cp ${./keymap.c} keyboards/ergodox_ez/keymaps/kyleondy/keymap.c
    cp ${./config.h} keyboards/ergodox_ez/keymaps/kyleondy/config.h
    cp ${./rules.mk} keyboards/ergodox_ez/keymaps/kyleondy/rules.mk
  '';

  buildPhase = ''
    runHook preBuild

    # Use make directly - avoids qmk CLI git dependencies
    make ergodox_ez:kyleondy

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    # The build creates ergodox_ez_base_kyleondy.hex (includes base variant)
    cp ergodox_ez_base_kyleondy.hex $out/

    runHook postInstall
  '';

  meta = with lib; {
    description = "Custom QMK firmware for Ergodox EZ (kyleondy layout)";
    license = licenses.gpl2Plus;
    platforms = platforms.linux;
  };
}
