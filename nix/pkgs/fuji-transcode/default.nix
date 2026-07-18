{
  writeShellApplication,
  ffmpeg,
  exiftool,
  coreutils,
}:

writeShellApplication {
  name = "fuji-transcode";
  runtimeInputs = [
    ffmpeg
    exiftool
    coreutils
  ];
  text = builtins.readFile ./fuji-transcode.sh;
}
