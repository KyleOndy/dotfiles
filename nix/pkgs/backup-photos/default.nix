{
  writeShellApplication,
  rsync,
  openssh,
}:

writeShellApplication {
  name = "backup-photos";
  runtimeInputs = [
    rsync
    openssh
  ];
  text = builtins.readFile ./backup-photos-to-dr.sh;
}
