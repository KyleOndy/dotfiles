{
  writeShellApplication,
  fetchurl,
  ffmpeg-headless,
  whisper-cpp,
  mkvtoolnix-cli,
  curl,
  jq,
  coreutils,
  util-linux,
  gnugrep,
  gawk,
}:

let
  # Language identification reads the first 30 seconds of a mel spectrogram, a
  # task the smallest model already saturates; the larger ones cost seconds per
  # sample and change no verdict.
  model = fetchurl {
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin";
    hash = "sha256-vgfgSOHlma1GNByNKhNWRQl6U4IhZ4t6zdGxkZxuGyE=";
  };
in
writeShellApplication {
  name = "audio-language-check";
  runtimeInputs = [
    ffmpeg-headless
    whisper-cpp
    # mkvpropedit: rewrites matroska track flags in the header, in place.
    mkvtoolnix-cli
    curl
    jq
    coreutils
    # logger, so verdicts land in the journal promtail already ships to Loki.
    util-linux
    gnugrep
    gawk
  ];
  text = ''
    export WHISPER_MODEL="''${WHISPER_MODEL:-${model}}"
    ${builtins.readFile ./audio-language-check.sh}
  '';
}
