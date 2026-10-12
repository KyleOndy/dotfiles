{ pkgs }:
pkgs.runCommand "alamode-coordinator-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.git
      pkgs.bash
      pkgs.flock
    ];
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export PYTHONPATH=${../pkgs/alamode-runtime}
    export ALAMODE_TEST_BIN=${pkgs.lib.getExe pkgs.llm-agents.pi}
    export ALAMODE_DELEGATE_SCRIPT=${../pkgs/alamode-delegate/alamode-delegate.py}
    ${pkgs.python3}/bin/python3 ${../pkgs/alamode-coordinator}/test_broker.py
    export ALAMODE_FORGE_SOURCE=${../pkgs/forge/forge.sh}
    ${pkgs.python3}/bin/python3 ${../pkgs/alamode-coordinator}/test_forge.py
    touch "$out"
  ''
