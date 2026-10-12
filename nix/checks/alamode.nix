# Native containment probes are opt-in in test_session.py; nested Seatbelt
# profiles cannot be exercised from the Nix build sandbox.
{ pkgs }:
let
  # A bundle named after a built-in grant fails at evaluation, where the
  # host config is authored, and never reaches a deployed wrapper.
  reservedBundle = builtins.tryEval (pkgs.alamode.override { bundles.forge.domains = [ ]; }).outPath;
  # A profile naming an unknown bundle fails the same way.
  reservedProfile =
    builtins.tryEval
      (pkgs.alamode.override { profiles.work.bundles = [ "no-such-bundle" ]; }).outPath;
in
assert pkgs.lib.assertMsg (!reservedBundle.success) "alamode accepted a bundle named forge";
assert pkgs.lib.assertMsg (
  !reservedProfile.success
) "alamode accepted a profile naming an unknown bundle";
pkgs.runCommand "alamode-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.git
      pkgs.zsh
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" tests
    cp ${../pkgs/alamode-runtime}/session.py tests/
    cp ${../pkgs/alamode-coordinator}/common.py tests/
    cp ${../pkgs/alamode-runtime}/workspace.py tests/
    cp ${../pkgs/alamode-runtime}/results.py tests/
    cp ${../pkgs/alamode-runtime}/test_session.py tests/
    cp ${../pkgs/alamode-runtime}/test_workspace.py tests/
    cp ${../pkgs/alamode-runtime}/test_results.py tests/
    cp ${../pkgs/alamode-runtime}/result-fixtures.json tests/
    python3 tests/test_session.py
    python3 tests/test_workspace.py
    python3 tests/test_results.py
    PYTHONPATH=${../pkgs/alamode-runtime}:${../pkgs/alamode-coordinator} python3 ${../pkgs/alamode-runtime}/test_build_service.py
    cp ${../../scripts/test-alamode.py} tests/test-alamode.py
    cp ${../../scripts/test_alamode.py} tests/test_alamode.py
    python3 tests/test_alamode.py
    ${pkgs.alamode}/bin/alamode --help > help.txt
    grep -q 'resume' help.txt
    grep -q 'coord' help.txt
    # The completion must load as a function named for the program, or TAB
    # completes nothing and zsh never says why.
    zsh -f -c '
      autoload -Uz compinit
      fpath=(${pkgs.alamode}/share/zsh/site-functions $fpath)
      compinit -u
      whence -w _alamode
    ' > completion.txt
    grep -q '_alamode: function' completion.txt
    touch "$out"
  ''
