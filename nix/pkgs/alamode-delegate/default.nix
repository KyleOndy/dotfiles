{
  writeShellApplication,
  python3,
}:
writeShellApplication {
  name = "alamode-delegate";
  runtimeInputs = [ python3 ];
  text = ''
    export PYTHONPATH=${../alamode-coordinator}
    exec ${python3}/bin/python3 ${./alamode-delegate.py} "$@"
  '';
}
