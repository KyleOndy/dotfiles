{
  writeShellApplication,
  rsync,
  openssh,
  findutils,
  awscli2,
  terraform,
}:

writeShellApplication {
  name = "backup-resolve-projects";
  runtimeInputs = [
    rsync
    openssh
    findutils
    awscli2
    terraform
  ];
  text = builtins.readFile ./backup-resolve-projects.sh;
}
