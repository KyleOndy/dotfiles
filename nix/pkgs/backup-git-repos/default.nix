{
  writeShellApplication,
  git,
  rsync,
  coreutils,
  findutils,
  openssh,
}:

writeShellApplication {
  name = "backup-git-repos";
  runtimeInputs = [
    git
    rsync
    coreutils
    findutils
    # rsync execs ssh by name for a remote destination and dies with
    # "Failed to exec ssh" without it on PATH.
    openssh
  ];
  text = builtins.readFile ./backup-git-repos.sh;
}
