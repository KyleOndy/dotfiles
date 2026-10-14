{
  runCommand,
  python3,
  nodejs,
  llm-agents,
}:
runCommand "alamode-runtime" { nativeBuildInputs = [ python3 ]; } ''
  mkdir -p "$out/libexec/alamode-runtime" "$out/bin"
  cp ${./session.py} "$out/libexec/alamode-runtime/session.py"
  cp ${./workspace.py} "$out/libexec/alamode-runtime/workspace.py"
  cp ${./results.py} "$out/libexec/alamode-runtime/results.py"
  cp ${./build_service.py} "$out/libexec/alamode-runtime/build_service.py"
  cp ${./build_client.py} "$out/libexec/alamode-runtime/build_client.py"
  cp ${./nix-canary.nix} "$out/libexec/alamode-runtime/nix-canary.nix"
  cp ${../alamode-coordinator/common.py} "$out/libexec/alamode-runtime/common.py"
  cat > "$out/bin/nix" <<EOF
  #!${python3}/bin/python3 -I
  import runpy
  runpy.run_path("$out/libexec/alamode-runtime/build_client.py", run_name="__main__")
  EOF
  chmod +x "$out/bin/nix"
  substitute ${./sandbox.mjs} "$out/libexec/alamode-runtime/sandbox.mjs" \
    --replace-fail '@sandboxRuntime@' '${llm-agents.sandbox-runtime}/lib/node_modules/@anthropic-ai/sandbox-runtime/dist/index.js'
  python3 -m py_compile "$out/libexec/alamode-runtime/"*.py
  ${nodejs}/bin/node --check "$out/libexec/alamode-runtime/sandbox.mjs"
''
