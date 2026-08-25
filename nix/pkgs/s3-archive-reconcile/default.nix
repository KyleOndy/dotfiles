{
  writeShellApplication,
  awscli2,
  zfs,
  jq,
  coreutils,
  findutils,
  systemd,
}:

writeShellApplication {
  name = "s3-archive-reconcile";
  # jq parses the key listing and builds the delete-objects payload; a key may
  # contain a tab, so --output text is not safe for either.
  runtimeInputs = [
    awscli2
    zfs
    jq
    coreutils
    findutils
    # systemctl, for the guard that keeps a comparison out of a live push.
    systemd
  ];
  text = builtins.readFile ./s3-archive-reconcile.sh;
}
