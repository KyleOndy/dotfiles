# Flake check that exercises the pi sandbox wrapper's decisions.
#
# Strategy: build the wrapper with a stubbed `pi` binary, then run it under
# PI_DEBUG=plan so each mode prints what it would exec (or the settings JSON
# it would hand to srt) instead of actually invoking bwrap / sandbox-exec / srt.
# Those primitives don't function inside the nix build sandbox; the check
# verifies the wrapper's *decisions*, not the real sandboxing.
{ pkgs }:
let
  stubPi = pkgs.writeShellScriptBin "pi" ''printf 'STUB_PI %s\n' "$*"'';

  wrapper = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
  };

  wrapperWithResolver = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    envFromCommands = {
      TEST_VAR = "echo hello";
    };
  };

  wrapperWithFailingResolver = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    envFromCommands = {
      BAD = "false";
    };
  };

  wrapperWithDefaultArgs = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultPiArgs = [
      "--model"
      "test-provider/test-model"
    ];
  };

  wrapperWithEnvVars = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultEnvVars = {
      TESTCACHE = "$PWD/.testcache";
    };
  };

  wrapperWithLoopback = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultAllowLoopback = true;
  };

  wrapperWithCustomIdentity = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    gitAuthorName = "Test Bot";
    gitAuthorEmail = "test-bot@example.invalid";
  };

  webExpect = if pkgs.stdenv.isLinux then "bwrap" else "sandbox-exec";
in
pkgs.runCommand "pi-coding-agent-check"
  {
    nativeBuildInputs = [
      wrapper
      pkgs.jq
    ];
  }
  ''
    set -euo pipefail

    export HOME=$TMPDIR/home
    mkdir -p "$HOME/.pi"
    export PI_DEBUG=plan

    fail() { echo "FAIL: $*" >&2; exit 1; }

    # --no-sandbox: warning + direct exec of stub pi
    captured=$(pi --no-sandbox foo 2>&1)
    echo "$captured" | grep -q "WARNING: running without sandbox" \
      || fail "--no-sandbox missing warning. captured=$captured"
    echo "$captured" | grep -q "PI_PLAN_EXEC.*pi.*foo" \
      || fail "--no-sandbox did not plan to exec stub pi. captured=$captured"

    # Strict default: srt invoked, settings JSON has expected shape
    captured=$(pi -- hello 2>&1)
    echo "$captured" | grep -q "PI_PLAN_EXEC.*srt --settings" \
      || fail "strict default did not plan srt. captured=$captured"
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    [ -n "$settings" ] || fail "strict default missing PI_PLAN_SETTINGS. captured=$captured"
    echo "$settings" | jq -e ".filesystem.denyRead | index(\"$HOME/.ssh\")" >/dev/null \
      || fail "denyRead missing ~/.ssh. settings=$settings"
    echo "$settings" | jq -e ".filesystem.denyRead | index(\"$HOME/.gnupg\")" >/dev/null \
      || fail "denyRead missing ~/.gnupg. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$HOME/.pi\")" >/dev/null \
      || fail "allowWrite missing ~/.pi. settings=$settings"
    echo "$settings" | jq -e ".network.allowedDomains == []" >/dev/null \
      || fail "allowedDomains should be empty by default. settings=$settings"
    echo "$settings" | jq -e ".allowPty == true" >/dev/null \
      || fail "allowPty should be true so pi's TUI can use setRawMode. settings=$settings"

    # --allow extends the domain allowlist
    captured=$(pi --allow example.com -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowedDomains | index("example.com")' >/dev/null \
      || fail "--allow did not extend allowedDomains. settings=$settings"

    # --allow-write extends the write-path list
    captured=$(pi --allow-write /tmp/x -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.filesystem.allowWrite | index("/tmp/x")' >/dev/null \
      || fail "--allow-write did not extend allowWrite. settings=$settings"

    # --web picks the right OS primitive for this platform
    captured=$(pi --web -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_EXEC.*${webExpect}" \
      || fail "--web did not plan ${webExpect}. captured=$captured"

    # Default envFromCommands={} emits no PI_PLAN_ENV: lines
    captured=$(pi -- x 2>&1)
    if echo "$captured" | grep -q "PI_PLAN_ENV:"; then
      fail "empty envFromCommands should emit no PI_PLAN_ENV. captured=$captured"
    fi

    # envFromCommands resolvers print intent under PI_DEBUG=plan
    captured=$(${wrapperWithResolver}/bin/pi -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_ENV: TEST_VAR=echo hello" \
      || fail "envFromCommands did not emit PI_PLAN_ENV. captured=$captured"

    # Failing resolver aborts pi before dispatch (PI_DEBUG unset so eval runs)
    unset PI_DEBUG
    if captured=$(${wrapperWithFailingResolver}/bin/pi -- x 2>&1); then
      fail "failing resolver should exit non-zero. captured=$captured"
    fi
    echo "$captured" | grep -q "resolver failed for \\\$BAD" \
      || fail "failing resolver missing diagnostic. captured=$captured"
    export PI_DEBUG=plan

    # defaultPiArgs prepends to pi's args
    captured=$(${wrapperWithDefaultArgs}/bin/pi -- --print hi 2>&1)
    echo "$captured" \
      | grep -q "PI_PLAN_EXEC.*pi --model test-provider/test-model --print hi" \
      || fail "defaultPiArgs missing from PI_PLAN_EXEC. captured=$captured"

    # Empty defaultPiArgs leaves the arg list untouched
    captured=$(pi -- --print hi 2>&1)
    if echo "$captured" | grep -q "PI_PLAN_EXEC.*pi --model"; then
      fail "empty defaultPiArgs should not inject --model. captured=$captured"
    fi

    # envVars expansion: $PWD resolves at wrapper runtime
    cd "$TMPDIR"
    captured=$(${wrapperWithEnvVars}/bin/pi -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_EXPORTED: TESTCACHE=$TMPDIR/.testcache" \
      || fail "envVars did not expand \$PWD. captured=$captured"

    # Empty envVars emits no PI_PLAN_EXPORTED: lines
    captured=$(pi -- x 2>&1)
    if echo "$captured" | grep -q "PI_PLAN_EXPORTED:"; then
      fail "empty envVars should emit no PI_PLAN_EXPORTED. captured=$captured"
    fi

    # defaultAllowLoopback=true → settings.network.allowLocalBinding == true
    captured=$(${wrapperWithLoopback}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowLocalBinding == true' >/dev/null \
      || fail "defaultAllowLoopback=true did not set allowLocalBinding. settings=$settings"

    # --allow-loopback CLI flag also flips it on a default-off wrapper
    captured=$(pi --allow-loopback -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowLocalBinding == true' >/dev/null \
      || fail "--allow-loopback did not set allowLocalBinding. settings=$settings"

    # Default (no flag, default off): allowLocalBinding is false
    captured=$(pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowLocalBinding == false' >/dev/null \
      || fail "default allowLocalBinding should be false. settings=$settings"

    # Default git identity is Kyle's Daemon and signing is disabled
    captured=$(pi -- x 2>&1)
    echo "$captured" | grep -qF "PI_PLAN_GIT: author=Kyle's Daemon <ai-daemon@noreply.ondy.org> sign=false" \
      || fail "default git identity missing. captured=$captured"

    # gitAuthorName/gitAuthorEmail overrides flow through
    captured=$(${wrapperWithCustomIdentity}/bin/pi -- x 2>&1)
    echo "$captured" | grep -qF "PI_PLAN_GIT: author=Test Bot <test-bot@example.invalid> sign=false" \
      || fail "custom git identity not applied. captured=$captured"

    # Git identity & sign=false apply under --no-sandbox too (commit
    # attribution must not depend on sandbox mode being on)
    captured=$(pi --no-sandbox foo 2>&1)
    echo "$captured" | grep -q "PI_PLAN_GIT:.*sign=false" \
      || fail "--no-sandbox dropped git identity. captured=$captured"

    touch $out
  ''
