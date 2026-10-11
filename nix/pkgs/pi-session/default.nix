{
  runCommand,
  python3,
  nodejs,
  llm-agents,
}:
runCommand "pi-session" { nativeBuildInputs = [ python3 ]; } ''
  mkdir -p "$out/libexec/pi-session" "$out/bin"
  cp ${./session.py} "$out/libexec/pi-session/session.py"
  cp ${./workspace.py} "$out/libexec/pi-session/workspace.py"
  cp ${./results.py} "$out/libexec/pi-session/results.py"
  cp ${./build_service.py} "$out/libexec/pi-session/build_service.py"
  cp ${./build_client.py} "$out/libexec/pi-session/build_client.py"
  cp ${../pi-broker/common.py} "$out/libexec/pi-session/common.py"
  cat > "$out/bin/nix" <<EOF
  #!${python3}/bin/python3 -I
  import runpy
  runpy.run_path("$out/libexec/pi-session/build_client.py", run_name="__main__")
  EOF
  chmod +x "$out/bin/nix"
  substitute ${./sandbox.mjs} "$out/libexec/pi-session/sandbox.mjs" \
    --replace-fail '@sandboxRuntime@' '${llm-agents.sandbox-runtime}/lib/node_modules/@anthropic-ai/sandbox-runtime/dist/index.js'
  python3 -m py_compile "$out/libexec/pi-session/"*.py
  ${nodejs}/bin/node --check "$out/libexec/pi-session/sandbox.mjs"
''
