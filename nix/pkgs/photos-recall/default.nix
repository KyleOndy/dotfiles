{
  writeShellApplication,
  rsync,
  openssh,
}:

writeShellApplication {
  name = "photos-recall";
  runtimeInputs = [
    rsync
    openssh
  ];
  text = builtins.readFile ./photos-recall.sh;
}
