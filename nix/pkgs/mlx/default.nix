{
  writeShellApplication,
  coreutils,
  curl,
  jq,
  python312,
  uv,
}:

writeShellApplication {
  name = "mlx";
  runtimeInputs = [
    coreutils
    curl
    jq
    uv
  ];
  text = ''
    readonly REQUIREMENTS=${./requirements.txt}
    readonly PYTHON=${python312}/bin/python3.12
  ''
  + builtins.readFile ./mlx.sh;
}
