{ pkgs }:
pkgs.runCommand "pi-delegate-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.git
    ];
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export PYTHONPATH=${../pkgs/pi-session}
    export PI_DELEGATE_SCRIPT=${../pkgs/pi-delegate/pi-delegate.py}
    ${pkgs.python3}/bin/python3 ${../pkgs/pi-broker}/test_broker.py BrokerTests.test_delegate_cli_uses_same_supervisor
    ${pkgs.pi-delegate}/bin/pi-delegate --help >/dev/null
    touch "$out"
  ''
