{
  writeShellApplication,
  curl,
  jq,
}:

writeShellApplication {
  name = "kagi";
  runtimeInputs = [
    curl
    jq
  ];
  text = builtins.readFile ./kagi.sh;
}
