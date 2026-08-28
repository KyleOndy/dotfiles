{
  writeShellApplication,
  curl,
  jq,
  git,
}:

writeShellApplication {
  name = "mcloud-pins";
  runtimeInputs = [
    curl
    jq
    git
  ];
  text = builtins.readFile ./mcloud-pins.sh;
}
