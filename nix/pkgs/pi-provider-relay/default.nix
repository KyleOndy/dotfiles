{ runCommand, python3 }:
runCommand "pi-provider-relay" { nativeBuildInputs = [ python3 ]; } ''
  mkdir -p "$out/libexec/pi-provider-relay"
  cp ${./relay.py} "$out/libexec/pi-provider-relay/relay.py"
  python3 -m py_compile "$out/libexec/pi-provider-relay/relay.py"
''
