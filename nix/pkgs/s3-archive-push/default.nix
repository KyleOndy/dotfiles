{
  writeShellApplication,
  awscli2,
  zfs,
  coreutils,
  findutils,
  gnugrep,
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
    gnugrep
  ];
  text = builtins.readFile ./s3-archive-push.sh;
}
