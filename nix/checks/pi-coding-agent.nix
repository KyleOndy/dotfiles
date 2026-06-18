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

  wrapperWithReadPaths = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultReadPaths = [ "/opt/toolchain" ];
  };

  # A secret-suffixed env var injected via envVars must survive the scrub
  # (its name is added to the keep-list), unlike a same-suffixed var that
  # merely leaked in from the caller's shell.
  wrapperWithSecretEnvVar = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultEnvVars = {
      DEPLOY_TOKEN = "injected-on-purpose";
    };
  };

  wrapperWithLoopback = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultAllowLoopback = true;
  };

  wrapperWithTrustdDefault = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultAllowTrustd = true;
  };

  wrapperWithBundles = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    networkBundles = {
      netbundle = {
        domains = [
          "test.example.com"
          "alt.example.com"
        ];
      };
      trustbundle = {
        domains = [ "trust.example.com" ];
        trustd = true;
      };
    };
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
    # Default-deny reads: all of $HOME denied, CWD + ~/.pi re-allowed
    echo "$settings" | jq -e ".filesystem.denyRead | index(\"$HOME\")" >/dev/null \
      || fail "default-deny: denyRead should contain \$HOME. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$HOME/.pi\")" >/dev/null \
      || fail "allowRead missing ~/.pi. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$PWD\")" >/dev/null \
      || fail "allowRead missing CWD. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$HOME/.pi\")" >/dev/null \
      || fail "allowWrite missing ~/.pi. settings=$settings"
    echo "$settings" | jq -e ".network.allowedDomains == []" >/dev/null \
      || fail "allowedDomains should be empty by default. settings=$settings"
    echo "$settings" | jq -e ".allowPty == true" >/dev/null \
      || fail "allowPty should be true so pi's TUI can use setRawMode. settings=$settings"
    # Git persistence traps: denyWrite carries the .git write-traps (item 3)
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$PWD/.git/hooks\")" >/dev/null \
      || fail "denyWrite missing \$PWD/.git/hooks. settings=$settings"
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$PWD/.git/config\")" >/dev/null \
      || fail "denyWrite missing \$PWD/.git/config. settings=$settings"

    # Git config hardening: gpgsign off + hooksPath neutered (item 2)
    captured=$(pi -- hello 2>&1)
    echo "$captured" | grep -q "PI_PLAN_GIT:.*sign=false hooksPath=/dev/null" \
      || fail "git hardening (hooksPath) missing. captured=$captured"

    # Supply-chain + cache hardening env (items 1 + 4)
    echo "$captured" | grep -q "PI_PLAN_HARDENING: npm_config_ignore_scripts=true" \
      || fail "npm lifecycle-script blocking missing. captured=$captured"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: YARN_ENABLE_SCRIPTS=false" \
      || fail "yarn script blocking missing. captured=$captured"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: GOCACHE=$HOME/.pi/sandbox-cache/go-build" \
      || fail "GOCACHE redirect missing. captured=$captured"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: CARGO_HOME=$HOME/.pi/sandbox-cache/cargo" \
      || fail "CARGO_HOME redirect missing. captured=$captured"

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

    # --allow-read extends the read-path allowlist (and is not shadowed by the
    # --allow-* bundle catch-all)
    captured=$(pi --allow-read /tmp/r -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.filesystem.allowRead | index("/tmp/r")' >/dev/null \
      || fail "--allow-read did not extend allowRead. settings=$settings"

    # --allow-read expands a leading ~ to $HOME
    captured=$(pi --allow-read '~/readme' -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$HOME/readme\")" >/dev/null \
      || fail "--allow-read did not expand ~ to \$HOME. settings=$settings"

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

    # defaultReadPaths is added to the strict-mode read allowlist
    captured=$(${wrapperWithReadPaths}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.filesystem.allowRead | index("/opt/toolchain")' >/dev/null \
      || fail "defaultReadPaths did not extend allowRead. settings=$settings"

    # Secret-suffix env scrub (item 5): a leaked *_TOKEN is stripped, a
    # provider key in the keep-list survives.
    captured=$(LEAKY_API_TOKEN=sk-xyz ANTHROPIC_API_KEY=keep-me pi -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_SCRUBBED: LEAKY_API_TOKEN" \
      || fail "secret scrub did not strip LEAKY_API_TOKEN. captured=$captured"
    if echo "$captured" | grep -q "PI_PLAN_SCRUBBED: ANTHROPIC_API_KEY"; then
      fail "secret scrub wrongly stripped kept ANTHROPIC_API_KEY. captured=$captured"
    fi
    # Differential: a leaked OTHER_TOKEN is scrubbed, but the same-suffixed
    # DEPLOY_TOKEN injected via envVars is kept (its name joins the keep-list).
    captured=$(OTHER_TOKEN=leaked ${wrapperWithSecretEnvVar}/bin/pi -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_SCRUBBED: OTHER_TOKEN" \
      || fail "scrub did not strip leaked OTHER_TOKEN. captured=$captured"
    if echo "$captured" | grep -q "PI_PLAN_SCRUBBED: DEPLOY_TOKEN"; then
      fail "scrub wrongly stripped envVars-injected DEPLOY_TOKEN. captured=$captured"
    fi

    # NODE_OPTIONS scrub (item 7): code-injection flags dropped, benign kept.
    captured=$(NODE_OPTIONS="--require /tmp/evil.js --max-old-space-size=4096" pi -- x 2>&1)
    nodeopts=$(echo "$captured" | sed -n 's/^PI_PLAN_NODE_OPTIONS: //p')
    echo "$nodeopts" | grep -q "max-old-space-size=4096" \
      || fail "NODE_OPTIONS scrub dropped the benign flag. captured=$captured"
    if echo "$nodeopts" | grep -q "require"; then
      fail "NODE_OPTIONS scrub kept --require injection. captured=$captured"
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

    # Trustd default off: enableWeakerNetworkIsolation is false
    captured=$(pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.enableWeakerNetworkIsolation == false' >/dev/null \
      || fail "default enableWeakerNetworkIsolation should be false. settings=$settings"

    # --allow-trustd CLI flag flips enableWeakerNetworkIsolation
    captured=$(pi --allow-trustd -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.enableWeakerNetworkIsolation == true' >/dev/null \
      || fail "--allow-trustd did not set enableWeakerNetworkIsolation. settings=$settings"

    # defaultAllowTrustd=true sets enableWeakerNetworkIsolation without any CLI flag
    captured=$(${wrapperWithTrustdDefault}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.enableWeakerNetworkIsolation == true' >/dev/null \
      || fail "defaultAllowTrustd=true did not set enableWeakerNetworkIsolation. settings=$settings"

    # Default wrapper has no bundles; --allow-<x> errors with diagnostic
    if captured=$(pi --allow-go -- x 2>&1); then
      fail "default wrapper should reject --allow-go. captured=$captured"
    fi
    echo "$captured" | grep -q "unknown bundle: --allow-go" \
      || fail "missing unknown-bundle diagnostic for --allow-go. captured=$captured"

    # Plain-network bundle: extends allowedDomains, trustd stays off
    captured=$(${wrapperWithBundles}/bin/pi --allow-netbundle -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowedDomains | index("test.example.com")' >/dev/null \
      || fail "--allow-netbundle missing test.example.com. settings=$settings"
    echo "$settings" | jq -e '.network.allowedDomains | index("alt.example.com")' >/dev/null \
      || fail "--allow-netbundle missing alt.example.com. settings=$settings"
    echo "$settings" | jq -e '.enableWeakerNetworkIsolation == false' >/dev/null \
      || fail "--allow-netbundle should not flip trustd. settings=$settings"

    # Trustd-requiring bundle: extends domains AND flips trustd
    captured=$(${wrapperWithBundles}/bin/pi --allow-trustbundle -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowedDomains | index("trust.example.com")' >/dev/null \
      || fail "--allow-trustbundle missing trust.example.com. settings=$settings"
    echo "$settings" | jq -e '.enableWeakerNetworkIsolation == true' >/dev/null \
      || fail "--allow-trustbundle did not flip trustd. settings=$settings"

    # Unknown bundle on a wrapper with bundles errors with the known-list
    if captured=$(${wrapperWithBundles}/bin/pi --allow-nonexistent -- x 2>&1); then
      fail "--allow-nonexistent should exit non-zero. captured=$captured"
    fi
    echo "$captured" | grep -q "unknown bundle: --allow-nonexistent" \
      || fail "missing unknown-bundle diagnostic. captured=$captured"
    echo "$captured" | grep -qE "known: .*(netbundle|trustbundle)" \
      || fail "known-bundles list missing in diagnostic. captured=$captured"

    # Existing exact-match flags aren't shadowed by the --allow-* catch-all
    captured=$(${wrapperWithBundles}/bin/pi --allow foo.example -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowedDomains | index("foo.example")' >/dev/null \
      || fail "--allow foo.example shadowed by --allow-* catch-all. settings=$settings"
    captured=$(${wrapperWithBundles}/bin/pi --allow-write /tmp/shadowtest -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.filesystem.allowWrite | index("/tmp/shadowtest")' >/dev/null \
      || fail "--allow-write shadowed by --allow-* catch-all. settings=$settings"
    captured=$(${wrapperWithBundles}/bin/pi --allow-loopback -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowLocalBinding == true' >/dev/null \
      || fail "--allow-loopback shadowed by --allow-* catch-all. settings=$settings"

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
