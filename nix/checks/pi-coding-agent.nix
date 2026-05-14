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

    touch $out
  ''
