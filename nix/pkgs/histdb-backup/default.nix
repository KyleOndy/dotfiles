{
  writeShellApplication,
  sqlite,
  rsync,
  coreutils,
}:

writeShellApplication {
  name = "histdb-backup";
  runtimeInputs = [
    sqlite
    rsync
    coreutils
  ];
  text = builtins.readFile ./histdb-backup.sh;
}
