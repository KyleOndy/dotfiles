{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

# Upstream tags releases by date and ships a dynamically linked binary with
# the TFLite and ONNX runtimes beside it, so this is a repack rather than a
# Go build. Bump both fields together; the checksum is from the release's
# checksums.txt.
stdenv.mkDerivation (finalAttrs: {
  pname = "birdnet-go";
  version = "20260823";

  src = fetchurl {
    url = "https://github.com/tphakala/birdnet-go/releases/download/${finalAttrs.version}/birdnet-go-linux-arm64-${finalAttrs.version}.tar.gz";
    hash = "sha256-VNKAzrytlk+k4iW40Vl5p4T97jofPcjXe/Rqh7h378M=";
  };

  # The tarball has no top-level directory.
  sourceRoot = ".";

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  # libonnxruntime is dlopen'd, not linked, so nothing in the ELF headers
  # tells autoPatchelf the binary needs this directory on its RUNPATH.
  appendRunpaths = [ "${placeholder "out"}/lib" ];

  installPhase = ''
    runHook preInstall
    install -Dm755 birdnet-go $out/bin/birdnet-go
    install -Dm644 libtensorflowlite_c.so libonnxruntime.so -t $out/lib
    runHook postInstall
  '';

  meta = {
    description = "Realtime BirdNET soundscape analysis";
    homepage = "https://github.com/tphakala/birdnet-go";
    license = lib.licenses.cc-by-nc-sa-40;
    platforms = [ "aarch64-linux" ];
    mainProgram = "birdnet-go";
  };
})
