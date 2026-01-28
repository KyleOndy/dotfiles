{
  lib,
  stdenv,
  fetchurl,
  patchelf,
}:

let
  version = "1.8.1";

  # Platform-specific binary info
  # Hashes computed with: nix-prefetch-url <url> (without --unpack)
  sources = {
    x86_64-linux = {
      url = "https://github.com/schpet/linear-cli/releases/download/v${version}/linear-x86_64-unknown-linux-gnu.tar.xz";
      sha256 = "sha256-76m+Vk2/5rQQeJIyWgOX5tLsZdEoYKxMkmt58FpKt7o=";
    };
    aarch64-linux = {
      url = "https://github.com/schpet/linear-cli/releases/download/v${version}/linear-aarch64-unknown-linux-gnu.tar.xz";
      sha256 = "sha256-CBuxQ8rXKhn8Z0nWyxbPB7RBywDQdhLTuFzLYE8jEQo=";
    };
    aarch64-darwin = {
      url = "https://github.com/schpet/linear-cli/releases/download/v${version}/linear-aarch64-apple-darwin.tar.xz";
      sha256 = "sha256-7KI2VDG5xnhoW4NJLVnEOaN0ZiB47iExD30r2QMTNdg=";
    };
    x86_64-darwin = {
      url = "https://github.com/schpet/linear-cli/releases/download/v${version}/linear-x86_64-apple-darwin.tar.xz";
      sha256 = "sha256-/1dDsy3TDlsab1kVgZ+y+SV9M09085//ZjFwosW9l5g=";
    };
  };

  platformInfo =
    sources.${stdenv.hostPlatform.system}
      or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation rec {
  pname = "linear-cli";
  inherit version;

  # Work around the "unpacker appears to have produced no directories"
  # case that happens when the archive doesn't have a subdirectory.
  setSourceRoot = "sourceRoot=$(pwd)";

  src = fetchurl {
    inherit (platformInfo) url sha256;
  };

  nativeBuildInputs = lib.optionals stdenv.isLinux [
    patchelf
  ];

  buildInputs = lib.optionals stdenv.isLinux [
    stdenv.cc.cc.lib
  ];

  # Don't strip the binary - it contains embedded metadata from cargo-binstall
  dontStrip = true;
  # Don't patch ELF - patchelf corrupts the cargo-binstall standalone binary section
  # On NixOS, users will need to use steam-run or a similar FHS environment
  dontPatchELF = true;
  dontPatchShebangs = true;

  installPhase = ''
    mkdir -p $out/bin
    # The tarball unpacks to a subdirectory like linear-x86_64-unknown-linux-gnu/
    cp */linear $out/bin/
    chmod +x $out/bin/linear
  '';

  meta = with lib; {
    description = "Linear CLI - command line interface for Linear";
    homepage = "https://github.com/schpet/linear-cli";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
      "x86_64-darwin"
    ];
    license = licenses.mit;
    longDescription = ''
      NOTE: On pure NixOS, this package requires the unpatched binary to preserve
      cargo-binstall metadata. It will work on:
      - macOS (all versions)
      - WSL (has access to host OS's dynamic linker)
      - Non-NixOS Linux systems

      On pure NixOS, use with steam-run or nix-ld.
    '';
  };
}
