{
  writeShellApplication,
  coreutils,
  curl,
  jq,
  git,
}:

writeShellApplication {
  name = "mcloud-pins";
  runtimeInputs = [
    coreutils
    curl
    jq
    git
  ];
  text = builtins.readFile ./mcloud-pins.sh;
}
