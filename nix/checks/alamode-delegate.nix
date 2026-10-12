{ pkgs }:
pkgs.runCommand "alamode-delegate-check"
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
    export PYTHONPATH=${../pkgs/alamode-runtime}
    export ALAMODE_DELEGATE_SCRIPT=${../pkgs/alamode-delegate/alamode-delegate.py}
    ${pkgs.python3}/bin/python3 ${../pkgs/alamode-coordinator}/test_broker.py BrokerTests.test_delegate_cli_uses_same_supervisor
    ${pkgs.alamode-delegate}/bin/alamode-delegate --help >/dev/null
    touch "$out"
  ''
