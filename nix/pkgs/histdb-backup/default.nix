{
  writeShellApplication,
  sqlite,
  rsync,
  coreutils,
  openssh,
}:

writeShellApplication {
  name = "histdb-backup";
  runtimeInputs = [
    sqlite
    rsync
    coreutils
    # rsync execs ssh by name for a remote destination and dies with
    # "Failed to exec ssh" without it on PATH.
    openssh
  ];
  text = builtins.readFile ./histdb-backup.sh;
}
