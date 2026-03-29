{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  pkg-config,
  libdrm,
  libgbm,
  mesa,
  libinput,
  systemd,
  libxkbcommon,
  seatd,
  libcap,
  libglvnd,
}:

stdenv.mkDerivation rec {
  pname = "flutter-pi";
  version = "1.1.1";

  src = fetchFromGitHub {
    owner = "ardera";
    repo = "flutter-pi";
    rev = "release/${version}";
    hash = "sha256-rLO2g+WGxsTUljx7PtuDwY+nu0UmNWpVG6Y9sLCO87g=";
  };

  nativeBuildInputs = [
    cmake
    pkg-config
  ];

  buildInputs = [
    libdrm
    libgbm # gbm.pc (split from mesa in nixpkgs)
    libglvnd # egl.pc, glesv2.pc (mesa builds with glvnd, so .pc files live here)
    mesa # GL implementation
    libinput
    systemd # libsystemd, libudev
    libcap # libsystemd.pc requires libcap.pc but nixpkgs doesn't propagate it
    libxkbcommon
    seatd # libseat
  ];

  meta = with lib; {
    description = "A light-weight Flutter Engine Embedder for Raspberry Pi";
    homepage = "https://github.com/ardera/flutter-pi";
    license = licenses.mit;
    platforms = [ "aarch64-linux" ];
  };
}
