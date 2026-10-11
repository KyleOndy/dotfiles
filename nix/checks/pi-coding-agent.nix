# Native containment probes are opt-in in test_session.py; nested Seatbelt
# profiles cannot be exercised from the Nix build sandbox.
{ pkgs }:
let
  # A bundle named after a built-in grant fails at evaluation, where the
  # host config is authored, and never reaches a deployed wrapper.
  reservedBundle =
    builtins.tryEval
      (pkgs.pi-wrapper.override { networkBundles.forge.domains = [ ]; }).outPath;
in
assert pkgs.lib.assertMsg (!reservedBundle.success) "pi-wrapper accepted a bundle named forge";
pkgs.runCommand "pi-coding-agent-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.git
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" tests
    cp ${../pkgs/pi-session}/session.py tests/
    cp ${../pkgs/pi-broker}/common.py tests/
    cp ${../pkgs/pi-session}/workspace.py tests/
    cp ${../pkgs/pi-session}/results.py tests/
    cp ${../pkgs/pi-session}/test_session.py tests/
    cp ${../pkgs/pi-session}/test_workspace.py tests/
    cp ${../pkgs/pi-session}/test_results.py tests/
    cp ${../pkgs/pi-session}/result-fixtures.json tests/
    python3 tests/test_session.py
    python3 tests/test_workspace.py
    python3 tests/test_results.py
    PYTHONPATH=${../pkgs/pi-session}:${../pkgs/pi-broker} python3 ${../pkgs/pi-session}/test_build_service.py
    cp ${../../scripts/test-pi-sandbox.py} tests/test-pi-sandbox.py
    cp ${../../scripts/test_pi_sandbox.py} tests/test_pi_sandbox.py
    python3 tests/test_pi_sandbox.py
    ${pkgs.pi-wrapper}/bin/pi --session-help > help.txt
    grep -q 'resume-session' help.txt
    touch "$out"
  ''
