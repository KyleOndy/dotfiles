{
  writeShellApplication,
  curl,
  jq,
}:

writeShellApplication {
  name = "mcloud-rank";
  runtimeInputs = [
    curl
    jq
  ];
  text = builtins.readFile ./mcloud-rank.sh;
}
