{
  writeShellApplication,
  rsync,
  openssh,
  findutils,
}:

writeShellApplication {
  name = "backup-resolve-projects";
  runtimeInputs = [
    rsync
    openssh
    findutils
  ];
  text = builtins.readFile ./backup-resolve-projects.sh;
}
