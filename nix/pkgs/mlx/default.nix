{
  writeShellApplication,
  curl,
  jq,
}:

writeShellApplication {
  name = "mlx";
  runtimeInputs = [
    curl
    jq
  ];
  text = builtins.readFile ./mlx.sh;
}
