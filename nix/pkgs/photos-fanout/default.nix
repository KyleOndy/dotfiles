{
  writeShellApplication,
  awscli2,
  rsync,
  util-linux,
}:

writeShellApplication {
  name = "photos-fanout";
  runtimeInputs = [
    awscli2
    rsync
    util-linux # mountpoint(8), to detect the external HDD
  ];
  text = builtins.readFile ./photos-fanout.sh;
}
