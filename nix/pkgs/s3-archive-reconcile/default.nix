{
  writeShellApplication,
  awscli2,
  zfs,
  jq,
  coreutils,
  findutils,
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
  ];
  text = builtins.readFile ./s3-archive-reconcile.sh;
}
