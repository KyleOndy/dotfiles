{
  writeShellApplication,
  curl,
  jq,
}:

writeShellApplication {
  name = "search-mail";
  runtimeInputs = [
    curl
    jq
  ];
  text = builtins.readFile ./search-mail.sh;
}
