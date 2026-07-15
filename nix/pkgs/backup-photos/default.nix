{
  writeShellApplication,
  awscli2,
  terraform,
  rsync,
  openssh,
}:

writeShellApplication {
  name = "backup-photos-to-dr";
  runtimeInputs = [
    awscli2
    terraform
    rsync
    openssh
  ];
  text = builtins.readFile ./backup-photos-to-dr.sh;
}
