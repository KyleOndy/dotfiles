# Native containment probes are opt-in in test_session.py; nested Seatbelt
# profiles cannot be exercised from the Nix build sandbox. The one test
# that builds the /tmp transport directory skips there too, for the same
# reason: execute() runs unsandboxed on the host, where /tmp is writable.
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
    # A compiled pi loads .env from its working directory, which a session
    # can write, unless llm-agents builds it with
    # --no-compile-autoload-dotenv. The first run shows FORCE_COLOR colours
    # --help, so the second can only pass by ignoring the file.
    mkdir dotenv
    echo FORCE_COLOR=1 > dotenv/.env
    FORCE_COLOR=1 ${pkgs.lib.getExe pkgs.llm-agents.pi} --help > pi-colour.txt 2>&1
    grep -q $'\e\[' pi-colour.txt
    (cd dotenv && ${pkgs.lib.getExe pkgs.llm-agents.pi} --help) > pi-dotenv.txt 2>&1
    if grep -q $'\e\[' pi-dotenv.txt; then
      echo "pi loaded dotenv/.env" >&2
      exit 1
    fi
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
