{
  writeShellApplication,
  python3,
}:
writeShellApplication {
  name = "pi-delegate";
  runtimeInputs = [ python3 ];
  text = ''
    export PYTHONPATH=${../pi-broker}
    exec ${python3}/bin/python3 ${./pi-delegate.py} "$@"
  '';
}
