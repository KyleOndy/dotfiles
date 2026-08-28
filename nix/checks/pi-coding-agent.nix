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

  wrapperWithGitWriteOff = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    gitWriteMode = "off";
  };

  wrapperWithGitWriteAlways = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    gitWriteMode = "always";
  };

  # Protects the branch the fixture commits on, so the gate's decision has to
  # follow this list rather than the "main" default.
  wrapperWithProtectedFeature = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    protectedBranches = [ "feature" ];
  };

  wrapperWithNixDefault = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultAllowNix = true;
  };

  wrapperWithDockerDefault = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultAllowDocker = true;
  };

  wrapperWithWritePaths = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultWritePaths = [ "~/.kube/configs" ];
  };

  webExpect = if pkgs.stdenv.isLinux then "bwrap" else "sandbox-exec";
in
pkgs.runCommand "pi-coding-agent-check"
  {
    nativeBuildInputs = [
      wrapper
      pkgs.jq
      pkgs.git
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

    # PI_REAL_BIN is exported so an in-process extension (e.g. the task
    # subagent tool) can spawn the real binary directly, bypassing another
    # sandbox layer, instead of re-invoking this wrapper.
    captured=$(pi -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_REAL_BIN: ${stubPi}/bin/pi" \
      || fail "PI_REAL_BIN not exported to the resolved real-binary path. captured=$captured"

    # A caller-supplied PI_REAL_BIN override still wins and is re-exported
    # (not silently replaced by the build-time default).
    captured=$(PI_REAL_BIN=/tmp/other-pi pi -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_REAL_BIN: /tmp/other-pi" \
      || fail "PI_REAL_BIN override not honored/re-exported. captured=$captured"

    # Outside a repo the git knobs resolve to nothing and add no paths
    cd "$TMPDIR"
    captured=$(pi -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_GIT_DIRS: dir=none common=none branch=none write=false" \
      || fail "non-repo cwd should resolve no git dirs. captured=$captured"

    # Fixture: primary checkout on main, a linked worktree on a feature branch
    # (git dir outside the workspace, the layout that broke every git command),
    # and a detached one.
    repo=$TMPDIR/repo
    git init -q -b main "$repo"
    git -C "$repo" -c user.name=check -c user.email=check@example.invalid \
      commit -q --allow-empty -m init
    git -C "$repo" worktree add -q -b feature "$TMPDIR/wt-feature"
    git -C "$repo" worktree add -q --detach "$TMPDIR/wt-detached"
    wt_gitdir=$repo/.git/worktrees/wt-feature

    # Primary checkout on a protected branch: git dir readable, and denied for
    # writes even though it sits inside the writable workspace.
    cd "$repo"
    captured=$(pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$repo/.git\")" >/dev/null \
      || fail "git dir must be readable. settings=$settings"
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$repo/.git\")" >/dev/null \
      || fail "protected branch must deny the git dir. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$repo/.git\") == null" >/dev/null \
      || fail "protected branch must not grant git-dir write. settings=$settings"

    # --allow-git-write overrides the branch gate
    captured=$(pi --allow-git-write -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$repo/.git\")" >/dev/null \
      || fail "--allow-git-write did not grant git-dir write. settings=$settings"

    # Linked worktree on a feature branch: both dirs readable, common dir
    # writable, traps on the resolved paths, protected refs still denied.
    cd "$TMPDIR/wt-feature"
    captured=$(pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$captured" | grep -q "PI_PLAN_GIT_DIRS:.*branch=feature write=true" \
      || fail "feature worktree should grant git write. captured=$captured"
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$repo/.git\")" >/dev/null \
      || fail "worktree: common dir not readable. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$wt_gitdir\")" >/dev/null \
      || fail "worktree: per-worktree git dir not readable. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$repo/.git\")" >/dev/null \
      || fail "worktree: common dir not writable, cannot commit. settings=$settings"
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$repo/.git/hooks\")" >/dev/null \
      || fail "worktree: hooks trap missing on the resolved dir. settings=$settings"
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$repo/.git/config\")" >/dev/null \
      || fail "worktree: config trap missing on the resolved dir. settings=$settings"
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$wt_gitdir/config.worktree\")" >/dev/null \
      || fail "worktree: config.worktree trap missing. settings=$settings"
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$repo/.git/refs/heads/main\")" >/dev/null \
      || fail "worktree: main's ref must stay denied. settings=$settings"
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$repo/.git/logs/refs/heads/main\")" >/dev/null \
      || fail "worktree: main's reflog must stay denied. settings=$settings"
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$repo/.git\") == null" >/dev/null \
      || fail "worktree: blanket git-dir deny would defeat the grant. settings=$settings"

    # --no-git-write withholds it again
    captured=$(pi --no-git-write -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$repo/.git\") == null" >/dev/null \
      || fail "--no-git-write still granted git-dir write. settings=$settings"
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$repo/.git\")" >/dev/null \
      || fail "--no-git-write did not deny the git dir. settings=$settings"

    # gitWriteMode="off" refuses on a non-protected branch
    captured=$(${wrapperWithGitWriteOff}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$repo/.git\") == null" >/dev/null \
      || fail "gitWriteMode=off granted git-dir write. settings=$settings"

    # protectedBranches is what the gate consults: protecting "feature"
    # withholds write on this same worktree.
    captured=$(${wrapperWithProtectedFeature}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$repo/.git\") == null" >/dev/null \
      || fail "protectedBranches=[feature] granted write anyway. settings=$settings"

    # Detached HEAD has no branch to commit onto: treated as protected
    cd "$TMPDIR/wt-detached"
    captured=$(pi -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_GIT_DIRS:.*branch=none write=false" \
      || fail "detached HEAD should not grant git write. captured=$captured"

    # gitWriteMode="always" ignores both the branch and the detached state
    captured=$(${wrapperWithGitWriteAlways}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$repo/.git\")" >/dev/null \
      || fail "gitWriteMode=always did not grant git-dir write. settings=$settings"

    # Unix sockets stay blocked unless --allow-nix asks for the daemon
    cd "$TMPDIR"
    captured=$(pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowUnixSockets == []' >/dev/null \
      || fail "allowUnixSockets should be empty by default. settings=$settings"
    echo "$captured" | grep -q "WARNING: --allow-nix" \
      && fail "warned about a nix grant that was never made. captured=$captured"

    captured=$(pi --allow-nix -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowUnixSockets | index("/nix/var/nix/daemon-socket/socket")' >/dev/null \
      || fail "--allow-nix did not allow the daemon socket. settings=$settings"
    # The grant is equivalent to --no-sandbox under trusted-users, so it has to
    # say so on the way past rather than only in a comment nobody reads.
    echo "$captured" | grep -q "WARNING: --allow-nix" \
      || fail "--allow-nix granted the socket without warning. captured=$captured"
    echo "$captured" | grep -q "unsandboxed" \
      || fail "--allow-nix warning does not name the consequence. captured=$captured"
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$HOME/.nix-defexpr\")" >/dev/null \
      || fail "--allow-nix missing the channel search path. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$HOME/.local/state/nix\")" >/dev/null \
      || fail "--allow-nix missing the channels symlink target. settings=$settings"

    # defaultAllowNix=true does the same without any CLI flag
    captured=$(${wrapperWithNixDefault}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowUnixSockets | index("/nix/var/nix/daemon-socket/socket")' >/dev/null \
      || fail "defaultAllowNix=true did not allow the daemon socket. settings=$settings"

    # --allow-docker grants one lima instance's socket, and the instance has to
    # declare what bounds the grant, so the fixture is that instance's config.
    # Written the way lima persists it: verbatim JSON of what it was created
    # from (nix/pkgs/forge/vm.nix), including the deny pair its portForwards end
    # in. `deny` is two rules because guestIP selects one address family.
    forge_dir=$HOME/.lima/forge
    forge_socket=$forge_dir/sock/docker.sock
    mk_instance() {
      mkdir -p "$forge_dir"
      jq -n --argjson mounts "$1" --argjson deny "$2" \
        '{mounts: $mounts, portForwards: ([{guestSocket: "/var/run/docker.sock"}] + $deny)}' \
        >"$forge_dir/lima.yaml"
    }
    deny_pair='[{"guestIP":"127.0.0.1","proto":"any","ignore":true},
                {"guestIP":"0.0.0.0","proto":"any","ignore":true}]'

    mk_instance '[]' "$deny_pair"
    captured=$(pi --allow-docker -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg s "$forge_socket" '.network.allowUnixSockets | index($s)' >/dev/null \
      || fail "--allow-docker did not allow the instance socket. settings=$settings"
    echo "$settings" | jq -e --arg s "$forge_socket" '.filesystem.allowRead | index($s)' >/dev/null \
      || fail "--allow-docker left the socket path unreadable. settings=$settings"

    # ~/.docker holds registry credentials and credentialMasks covers it, so the
    # grant must not re-allow it. DOCKER_CONFIG is what keeps the CLI working.
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$HOME/.docker\")" >/dev/null \
      && fail "--allow-docker re-allowed ~/.docker. settings=$settings"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: DOCKER_CONFIG=$HOME/.pi/sandbox-cache/docker" \
      || fail "--allow-docker did not redirect DOCKER_CONFIG. captured=$captured"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: DOCKER_HOST=unix://$forge_socket" \
      || fail "--allow-docker did not point DOCKER_HOST at the granted socket. captured=$captured"

    # The socket path is not taken from the environment. It was, and since it
    # becomes an allowRead entry, a .envrc in the checkout could pick any path
    # for the sandbox to grant.
    captured=$(DOCKER_HOST=unix:///Users/nobody/.ssh/agent.sock pi --allow-docker -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.filesystem.allowRead | index("/Users/nobody/.ssh/agent.sock")' >/dev/null \
      && fail "DOCKER_HOST chose a granted read path. settings=$settings"
    echo "$settings" | jq -e --arg s "$forge_socket" '.network.allowUnixSockets == [$s]' >/dev/null \
      || fail "DOCKER_HOST changed the granted socket. settings=$settings"
    captured=$(LIMA_HOME=/Users/nobody/evil pi --allow-docker -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg s "$forge_socket" '.network.allowUnixSockets == [$s]' >/dev/null \
      || fail "LIMA_HOME changed the granted socket. settings=$settings"

    # A mount is the case that matters: anything reaching the socket can start a
    # privileged container, which reads every path the VM has.
    mk_instance '[{"location":"~","writable":true}]' "$deny_pair"
    if captured=$(pi --allow-docker -- x 2>&1); then
      fail "--allow-docker granted a socket on a VM mounting \$HOME. captured=$captured"
    fi
    echo "$captured" | grep -q "mounts a host path" \
      || fail "refusal did not name the mount. captured=$captured"

    # lima appends its own forward-everything fallback after the last rule, so a
    # list that merely omits ports does not deny them.
    mk_instance '[]' '[]'
    if captured=$(pi --allow-docker -- x 2>&1); then
      fail "--allow-docker granted a socket on a VM with no deny tail. captured=$captured"
    fi
    echo "$captured" | grep -q "does not deny the port" \
      || fail "refusal did not name the port forwards. captured=$captured"

    # No instance at all is a refusal too, not a grant of a path that does not
    # exist yet and could be created later.
    rm -rf "$forge_dir"
    if captured=$(pi --allow-docker -- x 2>&1); then
      fail "--allow-docker granted a socket with no instance. captured=$captured"
    fi
    echo "$captured" | grep -q "no lima instance" \
      || fail "refusal did not name the missing instance. captured=$captured"
    mk_instance '[]' "$deny_pair"

    # Without the flag nothing is granted, and the CLI is not pointed anywhere
    captured=$(pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowUnixSockets == []' >/dev/null \
      || fail "a compliant instance alone should grant nothing. settings=$settings"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: DOCKER_HOST=" \
      && fail "DOCKER_HOST set without the grant. captured=$captured"

    # Both flags together, which is the case that exercises the socket list
    # rather than a single-element shortcut
    captured=$(pi --allow-nix --allow-docker -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowUnixSockets | length == 2' >/dev/null \
      || fail "--allow-nix --allow-docker did not yield both sockets. settings=$settings"

    # defaultAllowDocker=true does the same without any CLI flag
    captured=$(${wrapperWithDockerDefault}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg s "$forge_socket" '.network.allowUnixSockets | index($s)' >/dev/null \
      || fail "defaultAllowDocker=true did not allow the socket. settings=$settings"

    # defaultWritePaths reaches allowWrite, with ~ expanded
    captured=$(${wrapperWithWritePaths}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$HOME/.kube/configs\")" >/dev/null \
      || fail "defaultWritePaths did not reach allowWrite. settings=$settings"

    # TMPDIR is redirected into the write grant; no inherited temp dir is in it
    captured=$(pi -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_HARDENING: TMPDIR=$HOME/.pi/sandbox-cache/tmp" \
      || fail "TMPDIR not redirected under the cache root. captured=$captured"

    touch $out
  ''
