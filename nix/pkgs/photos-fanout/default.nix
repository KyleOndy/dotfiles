{
  writeShellApplication,
  awscli2,
}:

writeShellApplication {
  name = "photos-fanout";
  # rsync and util-linux went with the external HDD leg. Nothing left here
  # touches a local filesystem beyond reading the archive.
  runtimeInputs = [ awscli2 ];
  text = builtins.readFile ./photos-fanout.sh;
}
