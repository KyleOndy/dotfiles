{
  writeShellApplication,
  rsync,
  openssh,
}:

writeShellApplication {
  name = "photos-promote";
  runtimeInputs = [
    rsync
    openssh
  ];
  text = builtins.readFile ./photos-promote.sh;
}
