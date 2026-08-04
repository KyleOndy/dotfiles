{
  writeShellApplication,
  awscli2,
  zfs,
  coreutils,
  findutils,
}:

writeShellApplication {
  name = "s3-archive-push";
  # zfs for the mount guard, which is the only thing standing between an
  # unmounted receive target and a sync that reports success over an empty
  # tree.
  runtimeInputs = [
    awscli2
    zfs
    coreutils
    findutils
  ];
  text = builtins.readFile ./s3-archive-push.sh;
}
