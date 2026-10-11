{ pkgs }:
pkgs.runCommand "pi-broker-check"
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
    export PYTHONPATH=${../pkgs/pi-session}
    export PI_TEST_BIN=${pkgs.lib.getExe pkgs.llm-agents.pi}
    export PI_DELEGATE_SCRIPT=${../pkgs/pi-delegate/pi-delegate.py}
    ${pkgs.python3}/bin/python3 ${../pkgs/pi-broker}/test_broker.py
    export PI_FORGE_SOURCE=${../pkgs/forge/forge.sh}
    ${pkgs.python3}/bin/python3 ${../pkgs/pi-broker}/test_forge.py
    touch "$out"
  ''
