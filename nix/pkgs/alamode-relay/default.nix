{ runCommand, python3 }:
runCommand "alamode-relay" { nativeBuildInputs = [ python3 ]; } ''
  mkdir -p "$out/libexec/alamode-relay"
  cp ${./relay.py} "$out/libexec/alamode-relay/relay.py"
  python3 -m py_compile "$out/libexec/alamode-relay/relay.py"
''
