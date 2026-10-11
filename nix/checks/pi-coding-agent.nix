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
    # The daemon's config files are the host's; the check's assertions on
    # the --allow-nix warning must not depend on whichever daemon happens
    # to be under the build sandbox, so the posture probe reads nothing and
    # answers "unknown" here.
    nixDaemonConfigFiles = [ ];
  };

  # Posture probes: the daemon-side `sandbox` setting the --allow-nix
  # warning reads from nixDaemonConfigFiles. Separate fixtures so each
  # verdict has a deterministic input, independent of the check host.
  nixConfSandboxOff = pkgs.writeText "nix-custom" ''
    sandbox = false
  '';
  nixConfSandboxOn = pkgs.writeText "nix-custom" ''
    sandbox = true
  '';

  wrapperWithSandboxOff = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    nixDaemonConfigFiles = [ "${nixConfSandboxOff}" ];
  };

  wrapperWithSandboxOn = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    nixDaemonConfigFiles = [ "${nixConfSandboxOn}" ];
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

  settingsFixture = pkgs.writeText "pi-settings.json" ''{"shellPath":"/deployed/bash"}'';
  wrapperWithSettingsFile = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    settingsFile = "${settingsFixture}";
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

  wrapperWithSystemReadPaths = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultSystemReadPaths = [ "/opt/sysroot" ];
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
      pathbundle = {
        domains = [ "paths.example.com" ];
        readPaths = [ "~/.toolcache" ];
        writePaths = [ "~/.toolcache" ];
      };
      nixbundle = {
        domains = [ "nix.example.com" ];
        nix = true;
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

  wrapperWithSshAgentDefault = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultAllowSshAgent = true;
  };

  wrapperWithForgeDefault = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultAllowForge = true;
  };

  # Never run: the check plans the broker's start rather than making one.
  stubBroker = pkgs.writeShellScriptBin "pi-broker" "exit 1";

  wrapperWithBroker = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    coordinatorBroker = "${stubBroker}/bin/pi-broker";
    defaultEnvVars = {
      TMUX = "";
    };
  };

  wrapperWithWritePaths = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    defaultWritePaths = [ "~/.kube/configs" ];
  };

  # The seats file lives under the check's $HOME, so each case writes its own.
  wrapperWithSeats = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    seatsFile = "~/seats";
    trustedProviders = [ "fakecloud" ];
  };

  # Stands in for pi-seats, whose rules nix/checks/pi-seats.nix covers; this
  # check only needs the wrapper to call it and to obey its exit status.
  stubSeatsCheck = pkgs.writeShellScriptBin "pi-seats" ''
    printf 'SEATS_CHECK %s\n' "$*"
    [ ! -e "$HOME/fail-seats-check" ]
  '';

  wrapperWithSeatsCheck = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    seatsFile = "~/seats";
    trustedProviders = [ "fakecloud" ];
    seatsCheck = "${stubSeatsCheck}/bin/pi-seats";
  };

  # Trusts a provider on loopback too, whose host the sandbox must not list.
  wrapperWithCatalog = pkgs.pi-wrapper.override {
    realPiBin = "${stubPi}/bin/pi";
    trustedProviders = [
      "fakecloud"
      "loopcloud"
    ];
  };

  # A store path, as home-manager's link would be.
  catalogInStore = pkgs.writeText "models.json" (
    builtins.toJSON {
      providers = {
        fakecloud.baseUrl = "https://gw.fakecloud.test/v1";
        loopcloud.baseUrl = "http://127.0.0.1:11434/v1";
        othercloud.baseUrl = "https://other.test/v1";
      };
    }
  );

  webExpect = if pkgs.stdenv.isLinux then "bwrap" else "sandbox-exec";
  # One entry unique to this platform's defaultSystemReadPaths: /bin has to be
  # bound for /bin/sh to exist under bwrap, /System exists only on darwin.
  sysPathExpect = if pkgs.stdenv.isLinux then "/bin" else "/System";
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
    # pi's transcript directory for the cwd (getDefaultSessionDirPath, pi
    # 1.0.0): the physical path minus its leading /, separators replaced by -.
    proj_dir() {
      local p
      p=$(pwd -P)
      p=''${p#/}
      echo "--''${p//[\/\\:]/-}--"
    }

    # --no-sandbox: warning + direct exec of stub pi
    captured=$(pi --no-sandbox foo 2>&1)
    echo "$captured" | grep -q "WARNING: running without sandbox" \
      || fail "--no-sandbox missing warning. captured=$captured"
    echo "$captured" | grep -q "PI_PLAN_EXEC.*pi.*foo" \
      || fail "--no-sandbox did not plan to exec stub pi. captured=$captured"
    # No sandbox, so no grant is missing: listing the catalog would have the
    # agent ask for a restart over a refusal that cannot happen.
    echo "$captured" | grep -q "PI_PLAN_AVAILABLE_GRANTS" \
      && fail "--no-sandbox exported the grant catalog. captured=$captured"

    # Strict default: srt invoked, settings JSON has expected shape
    captured=$(pi -- hello 2>&1)
    echo "$captured" | grep -q "PI_PLAN_EXEC.*srt --settings" \
      || fail "strict default did not plan srt. captured=$captured"
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    [ -n "$settings" ] || fail "strict default missing PI_PLAN_SETTINGS. captured=$captured"
    # Nothing granted, so no grants record: PI_GRANTS is what
    # extensions/grants.ts keys its prompt sections off.
    if echo "$captured" | grep -q "PI_PLAN_GRANTS"; then
      fail "no grants passed, but PI_PLAN_GRANTS printed. captured=$captured"
    fi
    # Default-deny reads: "/" denied, CWD + ~/.pi + system paths re-allowed
    echo "$settings" | jq -e '.filesystem.denyRead | index("/")' >/dev/null \
      || fail "default-deny: denyRead must contain \"/\". settings=$settings"
    # Subagent transcripts are write-only. srt resolves by longest prefix, so
    # this deny reaches inside the ~/.pi read grant: task.ts records a fan-out
    # and no later agent can read one back. Denying the write too would leave
    # nothing able to record them, so assert that it is absent.
    echo "$settings" | jq -e --arg p "$HOME/.pi/agent/task-logs" '.filesystem.denyRead | index($p)' >/dev/null \
      || fail "task transcripts readable by the agent. settings=$settings"
    echo "$settings" | jq -e --arg p "$HOME/.pi/agent/task-logs" '.filesystem.denyWrite | index($p) | not' >/dev/null \
      || fail "task transcripts denied for write, nothing could record them. settings=$settings"
    echo "$settings" | jq -e '.filesystem.allowRead | index("${sysPathExpect}")' >/dev/null \
      || fail "allowRead missing ${sysPathExpect}. settings=$settings"
    echo "$settings" | jq -e '.filesystem.allowRead | index("/nix")' >/dev/null \
      || fail "allowRead missing /nix, nothing would run. settings=$settings"
    # The temp trees and mount points a $HOME-only deny leaves readable. They
    # hold $HOME content (another agent's scratchpad, a spill file, a backup
    # disk), so none of them may be named as a carve-out. A carve-out for
    # something underneath, $PWD under /Users, is the point of the allowlist.
    for leaky in / /Users /Volumes /tmp /private /private/tmp /private/var \
                 /private/var/folders "$HOME"; do
      echo "$settings" | jq -e --arg p "$leaky" '.filesystem.allowRead | index($p) | not' >/dev/null \
        || fail "allowRead re-opens $leaky. settings=$settings"
    done
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
    echo "$captured" | grep -q "PI_PLAN_GIT:.* editor=true" \
      || fail "GIT_EDITOR=true missing. captured=$captured"

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
    echo "$captured" | grep -q "PI_PLAN_ALLOWED_HOSTS: example.com" \
      || fail "--allow host missing from PI_ALLOWED_HOSTS. captured=$captured"

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

    # --allow-rw grants both directions at once, and in both lists expands ~
    captured=$(pi --allow-rw /tmp/rw -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.filesystem.allowWrite | index("/tmp/rw")' >/dev/null \
      || fail "--allow-rw did not extend allowWrite. settings=$settings"
    echo "$settings" | jq -e '.filesystem.allowRead | index("/tmp/rw")' >/dev/null \
      || fail "--allow-rw did not extend allowRead. settings=$settings"
    captured=$(pi --allow-rw '~/rwhome' -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$HOME/rwhome\")" >/dev/null \
      || fail "--allow-rw did not expand ~ to \$HOME in allowWrite. settings=$settings"

    # --web picks the right OS primitive for this platform
    captured=$(pi --web -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_EXEC.*${webExpect}" \
      || fail "--web did not plan ${webExpect}. captured=$captured"
    ${pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
      # --web buys the network, not the filesystem. Its macOS profile is
      # hand-written rather than srt's, because srt's schema refuses the
      # allowedDomains entry that would mean "any domain":
      #   network.allowedDomains.0: Invalid domain pattern ... Overly broad
      #   patterns like "*.com" or "*" are not allowed for security reasons
      # So the reads have to be denied here as well as in strict mode, and a
      # bare `(allow file-read*)` is exactly the regression this guards. Linux
      # needs no equivalent: bwrap binds an allowlist by construction.
      profile=$(echo "$captured" | sed -n 's/^PI_PLAN_PROFILE: //p')
      [ -n "$profile" ] || fail "--web emitted no PI_PLAN_PROFILE. captured=$captured"
      echo "$profile" | grep -q "(allow network\*)" \
        || fail "--web lost its unrestricted network. profile=$profile"
      if echo "$profile" | grep -qE '\(allow file-read\*\)'; then
        fail "--web re-opens every read. profile=$profile"
      fi
      echo "$profile" | grep -q '(allow file-read\* (subpath "/System"))' \
        || fail "--web dropped the system read paths. profile=$profile"
      echo "$profile" | grep -q '(allow file-read-metadata' \
        || fail "--web dropped realpath traversal metadata. profile=$profile"
      for leaky in /Users /Volumes /private/tmp /private/var/folders; do
        if echo "$profile" | grep -q "(allow file-read\* (subpath \"$leaky\"))"; then
          fail "--web re-opens $leaky. profile=$profile"
        fi
      done
      # --web carries the same session-scoped denies strict mode does, so the
      # wider network never comes with a narrower memory of the surface.
      # SBPL resolves by last match, so the project carve-out has to follow
      # the deny rather than sit in the allow list above it.
      web_deny="(deny file-read* (subpath \"$HOME/.pi/agent/sessions\"))"
      web_allow="(allow file-read* (subpath \"$HOME/.pi/agent/sessions/$(proj_dir)\"))"
      case "$profile" in
        *"$web_deny"*"$web_allow"*) ;;
        *)
          fail "--web must deny transcripts, then re-allow the project's own dir after the deny. profile=$profile"
          ;;
      esac
      # Seatbelt checks a rename against write rules alone, so a deny also
      # needs its subtree and its ancestors unmovable.
      web_unlink="(deny file-write-unlink (subpath \"$HOME/.pi/agent/sessions\"))"
      web_unlink_own="(allow file-write-unlink (subpath \"$HOME/.pi/agent/sessions/$(proj_dir)\"))"
      case "$profile" in
        *"$web_unlink"*"$web_unlink_own"*) ;;
        *)
          fail "--web must block moving transcripts out, except the project's own. profile=$profile"
          ;;
      esac
      echo "$profile" | grep -qF "(deny file-write-unlink (literal \"$HOME/.pi/agent\"))" \
        || fail "--web lets ~/.pi/agent move out from under its denies. profile=$profile"
      echo "$profile" | grep -q "(deny file-write\* (subpath \"$HOME/.pi/agent/extensions\"))" \
        || fail "--web left the extensions link writable. profile=$profile"
      # SBPL resolves by last match, so the project carve-out is only real if
      # it follows the deny covering it; the adjacency case above pins that,
      # and this pins the deny against drifting ahead of the allow list: the
      # last write-allow is the last line of the allow list, so the deny must
      # come after it, never before.
      last_allow="(allow file-write* (subpath \"$HOME/.pi\"))"
      case "$profile" in
        *"$last_allow"*"$web_deny"*) ;;
        *)
          fail "--web: the sessions deny must come after the allow list, last match wins. profile=$profile"
          ;;
      esac
    ''}

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

    # settingsFile is written over ~/.pi/agent/settings.json before dispatch,
    # replacing a symlink planted at the path rather than writing through it.
    mkdir -p "$HOME/.pi/agent"
    echo '{"shellPath":"/planted/sh"}' >"$HOME/.pi/agent/planted.json"
    ln -sf "$HOME/.pi/agent/planted.json" "$HOME/.pi/agent/settings.json"
    ${wrapperWithSettingsFile}/bin/pi -- x >/dev/null 2>&1
    [ ! -L "$HOME/.pi/agent/settings.json" ] \
      || fail "settingsFile wrote through a planted symlink"
    grep -q /deployed/bash "$HOME/.pi/agent/settings.json" \
      || fail "settingsFile did not replace settings.json. got=$(cat "$HOME/.pi/agent/settings.json")"
    grep -q /planted/sh "$HOME/.pi/agent/planted.json" \
      || fail "settingsFile clobbered the symlink's target"
    # An empty settingsFile leaves the file alone
    echo '{"theme":"kept"}' >"$HOME/.pi/agent/settings.json"
    pi -- x >/dev/null 2>&1
    grep -q kept "$HOME/.pi/agent/settings.json" \
      || fail "empty settingsFile touched settings.json"
    rm -f "$HOME/.pi/agent/settings.json" "$HOME/.pi/agent/planted.json"

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

    # defaultSystemReadPaths replaces the built-in system carve-outs
    captured=$(${wrapperWithSystemReadPaths}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.filesystem.allowRead | index("/opt/sysroot")' >/dev/null \
      || fail "defaultSystemReadPaths did not extend allowRead. settings=$settings"
    echo "$settings" | jq -e '.filesystem.allowRead | index("${sysPathExpect}") | not' >/dev/null \
      || fail "defaultSystemReadPaths should replace the defaults. settings=$settings"

    # srt prefers CLAUDE_CODE_TMPDIR and otherwise overwrites TMPDIR with
    # /tmp/claude, so both names have to carry the redirect for it to survive.
    captured=$(pi -- x 2>&1)
    for var in TMPDIR CLAUDE_CODE_TMPDIR; do
      echo "$captured" | grep -q "PI_PLAN_HARDENING: $var=$HOME/.pi/sandbox-cache/tmp" \
        || fail "$var not redirected into the sandbox cache. captured=$captured"
    done

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
    echo "$settings" | jq -e '.network.allowUnixSockets == []' >/dev/null \
      || fail "--allow-netbundle should not grant the nix daemon. settings=$settings"
    # Bundle names reach PI_GRANTS too, not just the exact-match flags.
    echo "$captured" | grep -q "PI_PLAN_GRANTS: netbundle" \
      || fail "--allow-netbundle missing PI_PLAN_GRANTS. captured=$captured"

    # PI_AVAILABLE_GRANTS is the full catalog this wrapper can carry,
    # exported unconditionally so a session carrying nothing still learns
    # what it could ask a restart for. extensions/grants.ts subtracts
    # PI_GRANTS from it for the prompt.
    captured=$(pi -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_AVAILABLE_GRANTS: clipboard,forge,git-crypt,nix,session-history,ssh-agent" \
      || fail "available grants missing or unsorted. captured=$captured"
    captured=$(${wrapperWithBundles}/bin/pi -- x 2>&1)
    echo "$captured" | grep -q \
      "PI_PLAN_AVAILABLE_GRANTS: clipboard,forge,git-crypt,netbundle,nix,nixbundle,pathbundle,session-history,ssh-agent,trustbundle" \
      || fail "bundles missing from available grants. captured=$captured"
    # Carrying a grant shrinks the missing list, never the catalog.
    captured=$(${wrapperWithBundles}/bin/pi --allow-netbundle -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_AVAILABLE_GRANTS: .*netbundle" \
      || fail "carried bundle vanished from available grants. captured=$captured"

    # Trustd-requiring bundle: extends domains AND flips trustd
    captured=$(${wrapperWithBundles}/bin/pi --allow-trustbundle -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowedDomains | index("trust.example.com")' >/dev/null \
      || fail "--allow-trustbundle missing trust.example.com. settings=$settings"
    echo "$settings" | jq -e '.enableWeakerNetworkIsolation == true' >/dev/null \
      || fail "--allow-trustbundle did not flip trustd. settings=$settings"

    # A bundle carrying filesystem grants, with the leading ~ expanded the way
    # defaultReadPaths is. This is what makes a toolchain whose caches live
    # under the denied $HOME one flag instead of a flag plus two --allow-reads.
    captured=$(${wrapperWithBundles}/bin/pi --allow-pathbundle -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$HOME/.toolcache\")" >/dev/null \
      || fail "--allow-pathbundle did not grant its read path. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$HOME/.toolcache\")" >/dev/null \
      || fail "--allow-pathbundle did not grant its write path. settings=$settings"

    # A bundle that declares no paths must leave both lists alone, or the two
    # new TSV fields word-split an empty string into a bogus grant.
    captured=$(${wrapperWithBundles}/bin/pi --allow-netbundle -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '[.filesystem.allowRead, .filesystem.allowWrite]
      | flatten | map(select(. == "")) | length == 0' >/dev/null \
      || fail "a path-less bundle leaked an empty path. settings=$settings"

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

    # The escape traps: a writable commondir or config.worktree redirects where
    # git reads config and hooks, so they stay denied across every worktree,
    # the session's own and (via the globs) siblings and later ones.
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$repo/.git/commondir\")" >/dev/null \
      || fail "worktree: commondir trap missing. settings=$settings"
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$repo/.git/worktrees/*/commondir\")" >/dev/null \
      || fail "worktree: sibling commondir glob trap missing. settings=$settings"
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$repo/.git/worktrees/*/config.worktree\")" >/dev/null \
      || fail "worktree: sibling config.worktree glob trap missing. settings=$settings"

    # Sibling worktree admin dirs hold their git-crypt keys, index and
    # in-progress rebase state: state this session never needs, granted anyway
    # by the blanket common-dir read. Denied on both axes, and the session's
    # own git dir must stay readable (asserted above) or git here would be
    # unusable.
    sibling="$repo/.git/worktrees/wt-detached"
    echo "$settings" | jq -e --arg s "$sibling" '.filesystem.denyRead | index($s)' >/dev/null \
      || fail "sibling worktree git dir readable: $sibling. settings=$settings"
    echo "$settings" | jq -e --arg s "$sibling" '.filesystem.denyWrite | index($s)' >/dev/null \
      || fail "sibling worktree git dir writable: $sibling. settings=$settings"
    # And no allow entry may reach it either: the deny is the carve-out, not
    # the only mention of the path.
    echo "$settings" | jq -e --arg s "$sibling" \
      '[(.filesystem.allowRead // []), (.filesystem.allowWrite // [])]
        | flatten | map(select(. == $s or startswith($s + "/"))) | length == 0' >/dev/null \
      || fail "a grant reaches into the sibling worktree dir. settings=$settings"

    # git-crypt's key file is the repo's master key for its ciphertext (tf/'s
    # *.pem, *.key, *.secret here), so its key dirs are denied by default,
    # the session's own included: running the clean filter and holding the
    # key are one capability. The glob covers siblings added after this
    # session started, which the broker makes outside the sandbox.
    echo "$settings" | jq -e --arg p "$wt_gitdir/git-crypt" '.filesystem.denyRead | index($p)' >/dev/null \
      || fail "own git-crypt key dir readable by default. settings=$settings"
    echo "$settings" | jq -e --arg p "$repo/.git/git-crypt" '.filesystem.denyRead | index($p)' >/dev/null \
      || fail "common-dir git-crypt key dir readable by default. settings=$settings"
    echo "$settings" | jq -e --arg p "$repo/.git/worktrees/*/git-crypt" '.filesystem.denyRead | index($p)' >/dev/null \
      || fail "git-crypt glob missing, later siblings' keys stay readable. settings=$settings"

    # --allow-git-crypt lifts the key denies and records the grant, so a
    # session that must commit tf/ can ask for a restart by name.
    captured=$(pi --allow-git-crypt -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$captured" | grep -q "PI_PLAN_GRANTS: git-crypt" \
      || fail "--allow-git-crypt missing from PI_PLAN_GRANTS. captured=$captured"
    echo "$settings" | jq -e --arg p "$wt_gitdir/git-crypt" '.filesystem.denyRead | index($p) | not' >/dev/null \
      || fail "--allow-git-crypt left the key deny in place. settings=$settings"
    echo "$settings" | jq -e --arg p "$repo/.git/worktrees/*/git-crypt" '.filesystem.denyRead | index($p) | not' >/dev/null \
      || fail "--allow-git-crypt left the sibling glob deny in place. settings=$settings"

    # Other projects' transcripts stay unreadable and unwritable, this
    # project's stay both. The read deny is a glob because srt carves
    # allowRead entries out of glob denies only.
    sess="$HOME/.pi/agent/sessions"
    mkdir -p "$sess/--other--"
    captured=$(pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    proj=$(proj_dir)
    echo "$settings" | jq -e --arg p "$sess/*" '.filesystem.denyRead | index($p)' >/dev/null \
      || fail "session transcripts readable across projects. settings=$settings"
    echo "$settings" | jq -e --arg p "$sess/--other--" '.filesystem.denyWrite | index($p)' >/dev/null \
      || fail "another project's transcripts writable. settings=$settings"
    echo "$settings" | jq -e --arg p "$sess" '.filesystem.allowRead | index($p) | not' >/dev/null \
      || fail "the sessions root must not be granted, only the project dir. settings=$settings"
    echo "$settings" | jq -e --arg p "$sess/$proj" '.filesystem.allowRead | index($p)' >/dev/null \
      || fail "the project's own transcript dir must stay readable. settings=$settings"
    echo "$settings" | jq -e --arg p "$sess/$proj" '.filesystem.denyWrite | index($p) | not' >/dev/null \
      || fail "the project's transcript dir must stay writable, pi records into it. settings=$settings"

    # --allow-session-history lifts the deny and records the grant: that is
    # what the resume picker and cross-project resume ask a restart for.
    captured=$(pi --allow-session-history -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$captured" | grep -q "PI_PLAN_GRANTS: session-history" \
      || fail "--allow-session-history missing from PI_PLAN_GRANTS. captured=$captured"
    echo "$settings" | jq -e --arg p "$sess/*" '.filesystem.denyRead | index($p) | not' >/dev/null \
      || fail "--allow-session-history left the deny in place. settings=$settings"
    echo "$settings" | jq -e --arg p "$sess/--other--" '.filesystem.denyWrite | index($p) | not' >/dev/null \
      || fail "--allow-session-history left another project write-denied. settings=$settings"

    # The loadable surface of ~/.pi/agent is home-manager's symlinks to code
    # and config pi loads at startup; ~/.pi is writable by every session, so
    # a swapped link is the next session's code execution. Denied for write.
    # keybindings.json is deliberately absent: pi rewrites it when an action
    # id is renamed upstream.
    captured=$(pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    for name in extensions grants agents skills themes AGENTS.md models.json; do
      echo "$settings" | jq -e --arg p "$HOME/.pi/agent/$name" '.filesystem.denyWrite | index($p)' >/dev/null \
        || fail "loadable $name writable: swap-to-code-exec. settings=$settings"
    done
    echo "$settings" | jq -e --arg p "$HOME/.pi/agent/keybindings.json" '.filesystem.denyWrite | index($p) | not' >/dev/null \
      || fail "keybindings.json must stay writable, pi rewrites it. settings=$settings"

    # --protect-branch adds a branch to the gate: a sibling's ref and reflog
    # join denyWrite while write on this branch is still granted.
    captured=$(pi --protect-branch=sibling -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$captured" | grep -q "PI_PLAN_GIT_DIRS:.*branch=feature write=true" \
      || fail "--protect-branch=sibling should not withhold write on feature. captured=$captured"
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$repo/.git/refs/heads/sibling\")" >/dev/null \
      || fail "--protect-branch did not deny the branch ref. settings=$settings"
    echo "$settings" | jq -e ".filesystem.denyWrite | index(\"$repo/.git/logs/refs/heads/sibling\")" >/dev/null \
      || fail "--protect-branch did not deny the branch reflog. settings=$settings"

    # Protecting the session's own branch withholds its git write, proving the
    # flag feeds the same gate protectedBranches does.
    captured=$(pi --protect-branch=feature -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_GIT_DIRS:.*branch=feature write=false" \
      || fail "--protect-branch=feature should withhold write on feature. captured=$captured"

    # An invalid branch name is refused, not passed through.
    pi --protect-branch=bad..name -- x >/dev/null 2>&1 \
      && fail "--protect-branch accepted an invalid branch name"

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

    # The pasteboard is a mach service, closed unless --allow-clipboard.
    echo "$settings" | jq -e '.network.allowMachLookup == []' >/dev/null \
      || fail "allowMachLookup should be empty by default. settings=$settings"
    captured=$(pi --allow-clipboard -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowMachLookup == ["com.apple.pasteboard.1"]' >/dev/null \
      || fail "--allow-clipboard did not allow the pasteboard. settings=$settings"
    echo "$captured" | grep -q "PI_PLAN_GRANTS: clipboard" \
      || fail "--allow-clipboard missing PI_PLAN_GRANTS. captured=$captured"

    # Determinate Nix on darwin points the well-known path at
    # /var/run/nix-daemon.socket, and seatbelt matches the target, so a wrapper
    # that grants only the link leaves nix reporting "Operation not permitted"
    # with the grant sitting in allowUnixSockets. Resolve it the same way the
    # wrapper does so the arity assertions below hold on either platform.
    nix_sock=/nix/var/nix/daemon-socket/socket
    nix_sock_real=$(readlink -f "$nix_sock" 2>/dev/null || true)
    nix_sock_count=1
    if [ -n "$nix_sock_real" ] && [ "$nix_sock_real" != "$nix_sock" ]; then
      nix_sock_count=2
    fi

    captured=$(pi --allow-nix -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowUnixSockets | index("/nix/var/nix/daemon-socket/socket")' >/dev/null \
      || fail "--allow-nix did not allow the daemon socket. settings=$settings"
    if [ "$nix_sock_count" -eq 2 ]; then
      echo "$settings" | jq -e --arg s "$nix_sock_real" '.network.allowUnixSockets | index($s)' >/dev/null \
        || fail "--allow-nix did not allow the resolved socket path. settings=$settings"
    fi
    # The grant lands in PI_GRANTS alongside the socket, which is how the
    # prompt learns what the socket costs.
    echo "$captured" | grep -q "PI_PLAN_GRANTS: nix" \
      || fail "--allow-nix missing PI_PLAN_GRANTS. captured=$captured"
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
    # Opening a remote store makes nix stat every $PATH entry looking for ssh,
    # and eval takes a write lock under ~/.cache/nix before it reaches the
    # first derivation, so a read-only grant there is not enough.
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$HOME/.nix-profile\")" >/dev/null \
      || fail "--allow-nix missing the profile on \$PATH. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$HOME/.cache/nix\")" >/dev/null \
      || fail "--allow-nix missing the eval cache. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$HOME/.cache/nix\")" >/dev/null \
      || fail "--allow-nix left the fetcher lock dir read-only. settings=$settings"

    # A bundle with nix = true, as flake is, carries the whole --allow-nix
    # grant, and the prompt learns its cost through nix in PI_GRANTS.
    captured=$(${wrapperWithBundles}/bin/pi --allow-nixbundle -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowUnixSockets | index("/nix/var/nix/daemon-socket/socket")' >/dev/null \
      || fail "--allow-nixbundle did not allow the daemon socket. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$HOME/.cache/nix\")" >/dev/null \
      || fail "--allow-nixbundle left the fetcher lock dir read-only. settings=$settings"
    echo "$settings" | jq -e '.network.allowedDomains | index("nix.example.com")' >/dev/null \
      || fail "--allow-nixbundle missing nix.example.com. settings=$settings"
    echo "$captured" | grep -q "PI_PLAN_GRANTS: nix,nixbundle" \
      || fail "--allow-nixbundle missing nix in PI_PLAN_GRANTS. captured=$captured"
    echo "$captured" | grep -q "WARNING: --allow-nix" \
      || fail "--allow-nixbundle granted the socket without warning. captured=$captured"

    # The warning has to match what the daemon reports rather than always
    # claiming the worst case, or it trains you to ignore it on the hosts
    # where the escalation is unavailable. Stub `nix` instead of depending on
    # whatever daemon the builder happens to have.
    mk_nix_stub() {
      mkdir -p "$TMPDIR/nixstub"
      printf '#!/bin/sh\nprintf %s\n' "'{\"trusted\":$1}'" >"$TMPDIR/nixstub/nix"
      chmod +x "$TMPDIR/nixstub/nix"
    }
    mk_nix_stub false
    captured=$(PATH=$TMPDIR/nixstub:$PATH pi --allow-nix -- x 2>&1)
    echo "$captured" | grep -q "untrusted" \
      || fail "--allow-nix did not report the untrusted verdict. captured=$captured"
    echo "$captured" | grep -q "unsandboxed" \
      && fail "--allow-nix called an untrusted client unsandboxed. captured=$captured"

    mk_nix_stub true
    captured=$(PATH=$TMPDIR/nixstub:$PATH pi --allow-nix -- x 2>&1)
    echo "$captured" | grep -q "unsandboxed" \
      || fail "--allow-nix did not warn on a trusted client. captured=$captured"

    # The builder-sandbox posture is the second bit the grant costs: with
    # sandbox=false a builder is unconfined code with the whole network, as
    # measured (writes /tmp, direct egress, no srt proxy). Read from the
    # daemon's own config files; the base wrapper was built with an empty
    # list, so its stubbed-trust cases above answer "unknown", which must
    # say so without borrowing the trusted verdict's word.
    mk_nix_stub false
    captured=$(PATH=$TMPDIR/nixstub:$PATH ${wrapperWithSandboxOff}/bin/pi --allow-nix -- x 2>&1)
    echo "$captured" | grep -q "does not sandbox its builds" \
      || fail "sandbox=false posture not reported. captured=$captured"
    echo "$captured" | grep -q "unsandboxed" \
      && fail "an untrusted client was called unsandboxed, whatever the posture. captured=$captured"
    captured=$(PATH=$TMPDIR/nixstub:$PATH ${wrapperWithSandboxOn}/bin/pi --allow-nix -- x 2>&1)
    echo "$captured" | grep -q "sandboxes its builds" \
      || fail "sandbox=true posture not reported. captured=$captured"
    echo "$captured" | grep -q "does not sandbox its builds" \
      && fail "sandbox=true posture contradicts itself. captured=$captured"
    captured=$(PATH=$TMPDIR/nixstub:$PATH pi --allow-nix -- x 2>&1)
    echo "$captured" | grep -q "could not tell whether the daemon sandboxes" \
      || fail "unknown posture not reported as unknown. captured=$captured"

    # defaultAllowNix=true does the same without any CLI flag
    captured=$(${wrapperWithNixDefault}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowUnixSockets | index("/nix/var/nix/daemon-socket/socket")' >/dev/null \
      || fail "defaultAllowNix=true did not allow the daemon socket. settings=$settings"

    # --allow-forge grants one forge instance's socket, and the instance has to
    # declare what bounds the grant, so the fixture is that instance's config.
    # Written the way lima persists it: verbatim JSON of what it was created
    # from (nix/pkgs/forge/vm.nix), including the deny pair its portForwards end
    # in. `deny` is two rules because guestIP selects one address family.
    forge_dir=$HOME/.lima/forge
    forge_socket=$forge_dir/sock/docker.sock
    mk_instance() {
      local dir=''${3:-$forge_dir}
      mkdir -p "$dir"
      jq -n --argjson mounts "$1" --argjson deny "$2" \
        '{mounts: $mounts, portForwards: ([{guestSocket: "/var/run/docker.sock"}] + $deny)}' \
        >"$dir/lima.yaml"
    }
    deny_pair='[{"guestIP":"127.0.0.1","proto":"any","ignore":true},
                {"guestIP":"0.0.0.0","proto":"any","ignore":true}]'

    mk_instance '[]' "$deny_pair"
    captured=$(pi --allow-forge -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg s "$forge_socket" '.network.allowUnixSockets | index($s)' >/dev/null \
      || fail "--allow-forge did not allow the instance socket. settings=$settings"
    echo "$settings" | jq -e --arg s "$forge_socket" '.filesystem.allowRead | index($s)' >/dev/null \
      || fail "--allow-forge left the socket path unreadable. settings=$settings"
    echo "$captured" | grep -q "PI_PLAN_GRANTS: forge" \
      || fail "--allow-forge missing PI_PLAN_GRANTS. captured=$captured"
    # `forge up` fetches the argo-cd chart itself, so the hosts come with the
    # grant rather than from a separate bundle.
    echo "$settings" | jq -e '.network.allowedDomains | index("argoproj.github.io")' >/dev/null \
      || fail "--allow-forge did not allow the chart repo. settings=$settings"
    # The unnamed instance's kubeconfig is the human's, so it is read-only.
    echo "$settings" | jq -e --arg p "$HOME/.local/state/forge/kubeconfig.yaml" \
      '(.filesystem.allowRead | index($p)) and (.filesystem.allowWrite | index($p) | not)' >/dev/null \
      || fail "--allow-forge did not grant the unnamed kubeconfig read-only. settings=$settings"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: FORGE_INSTANCE=" \
      && fail "the unnamed instance set FORGE_INSTANCE. captured=$captured"

    # ~/.docker holds registry credentials and credentialMasks covers it, so the
    # grant must not re-allow it. DOCKER_CONFIG is what keeps the CLI working.
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$HOME/.docker\")" >/dev/null \
      && fail "--allow-forge re-allowed ~/.docker. settings=$settings"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: DOCKER_CONFIG=$HOME/.pi/sandbox-cache/docker" \
      || fail "--allow-forge did not redirect DOCKER_CONFIG. captured=$captured"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: DOCKER_HOST=unix://$forge_socket" \
      || fail "--allow-forge did not point DOCKER_HOST at the granted socket. captured=$captured"

    # The socket path is not taken from the environment. It was, and since it
    # becomes an allowRead entry, a .envrc in the checkout could pick any path
    # for the sandbox to grant.
    captured=$(DOCKER_HOST=unix:///Users/nobody/.ssh/agent.sock pi --allow-forge -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.filesystem.allowRead | index("/Users/nobody/.ssh/agent.sock")' >/dev/null \
      && fail "DOCKER_HOST chose a granted read path. settings=$settings"
    echo "$settings" | jq -e --arg s "$forge_socket" '.network.allowUnixSockets == [$s]' >/dev/null \
      || fail "DOCKER_HOST changed the granted socket. settings=$settings"
    captured=$(LIMA_HOME=/Users/nobody/evil pi --allow-forge -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg s "$forge_socket" '.network.allowUnixSockets == [$s]' >/dev/null \
      || fail "LIMA_HOME changed the granted socket. settings=$settings"
    # Same for the instance: FORGE_INSTANCE in the environment selects nothing.
    captured=$(FORGE_INSTANCE=3 pi --allow-forge -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg s "$forge_socket" '.network.allowUnixSockets == [$s]' >/dev/null \
      || fail "FORGE_INSTANCE changed the granted socket. settings=$settings"

    # A mount is the case that matters: anything reaching the socket can start a
    # privileged container, which reads every path the VM has.
    mk_instance '[{"location":"~","writable":true}]' "$deny_pair"
    if captured=$(pi --allow-forge -- x 2>&1); then
      fail "--allow-forge granted a socket on a VM mounting \$HOME. captured=$captured"
    fi
    echo "$captured" | grep -q "mounts a host path" \
      || fail "refusal did not name the mount. captured=$captured"

    # lima appends its own forward-everything fallback after the last rule, so a
    # list that merely omits ports does not deny them.
    mk_instance '[]' '[]'
    if captured=$(pi --allow-forge -- x 2>&1); then
      fail "--allow-forge granted a socket on a VM with no deny tail. captured=$captured"
    fi
    echo "$captured" | grep -q "does not deny the port" \
      || fail "refusal did not name the port forwards. captured=$captured"

    # `limactl edit`, which `forge resize` runs, may persist the config as YAML,
    # and a resized instance must not lose its grant for that.
    printf '%s\n' 'mounts: []' 'portForwards:' \
      '  - guestSocket: /var/run/docker.sock' \
      '  - {guestIP: 127.0.0.1, proto: any, ignore: true}' \
      '  - {guestIP: 0.0.0.0, proto: any, ignore: true}' >"$forge_dir/lima.yaml"
    captured=$(pi --allow-forge -- x 2>&1) \
      || fail "--allow-forge refused an instance whose config lima wrote as YAML. captured=$captured"
    printf '%s\n' 'mounts: [{location: "~", writable: true}]' 'portForwards: []' >"$forge_dir/lima.yaml"
    if captured=$(pi --allow-forge -- x 2>&1); then
      fail "--allow-forge granted a YAML-configured VM mounting \$HOME. captured=$captured"
    fi

    # No instance at all is a refusal too, not a grant of a path that does not
    # exist yet and could be created later.
    rm -rf "$forge_dir"
    if captured=$(pi --allow-forge -- x 2>&1); then
      fail "--allow-forge granted a socket with no instance. captured=$captured"
    fi
    echo "$captured" | grep -q "no lima instance" \
      || fail "refusal did not name the missing instance. captured=$captured"
    mk_instance '[]' "$deny_pair"

    # A named instance is its own VM, socket and kubeconfig dir, and the grant
    # reaches none of the unnamed instance's. This is what keeps one agent's
    # session off another's clusters.
    forge3_dir=$HOME/.lima/forge-3
    forge3_socket=$forge3_dir/sock/docker.sock
    if captured=$(pi --allow-forge=3 -- x 2>&1); then
      fail "--allow-forge=3 granted with only the unnamed instance present. captured=$captured"
    fi
    echo "$captured" | grep -q "no lima instance at $forge3_dir" \
      || fail "refusal did not name instance 3. captured=$captured"
    mk_instance '[]' "$deny_pair" "$forge3_dir"
    captured=$(pi --allow-forge=3 -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg s "$forge3_socket" '.network.allowUnixSockets == [$s]' >/dev/null \
      || fail "--allow-forge=3 did not grant exactly instance 3's socket. settings=$settings"
    echo "$settings" | jq -e --arg p "$HOME/.local/state/forge/3" \
      '(.filesystem.allowRead | index($p)) and (.filesystem.allowWrite | index($p))' >/dev/null \
      || fail "--allow-forge=3 did not grant its instance dir. settings=$settings"
    echo "$settings" | jq -e --arg p "$HOME/.local/state/forge/kubeconfig.yaml" \
      '[.filesystem.allowRead, .filesystem.allowWrite] | flatten | index($p) | not' >/dev/null \
      || fail "--allow-forge=3 granted the unnamed instance's kubeconfig. settings=$settings"
    for kv in "FORGE_INSTANCE=3" "KUBECONFIG=$HOME/.local/state/forge/3/kubeconfig.yaml" "DOCKER_HOST=unix://$forge3_socket"; do
      echo "$captured" | grep -q "PI_PLAN_HARDENING: $kv" \
        || fail "--allow-forge=3 did not export $kv. captured=$captured"
    done
    # The value becomes a path component, so anything but 1-15 is refused.
    for bad in 0 16 03 abc "3/../../x" ""; do
      if captured=$(pi --allow-forge="$bad" -- x 2>&1); then
        fail "--allow-forge=$bad was accepted. captured=$captured"
      fi
      echo "$captured" | grep -q "takes a forge instance 1-15" \
        || fail "--allow-forge=$bad refusal missing diagnostic. captured=$captured"
    done

    # Without the flag nothing is granted, and the CLI is not pointed anywhere
    captured=$(pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowUnixSockets == []' >/dev/null \
      || fail "a compliant instance alone should grant nothing. settings=$settings"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: DOCKER_HOST=" \
      && fail "DOCKER_HOST set without the grant. captured=$captured"

    # Both flags together, which is the case that exercises the socket list
    # rather than a single-element shortcut
    captured=$(pi --allow-nix --allow-forge -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --argjson n "$((nix_sock_count + 1))" \
      '.network.allowUnixSockets | length == $n' >/dev/null \
      || fail "--allow-nix --allow-forge did not yield both sockets. settings=$settings"

    # defaultAllowForge=true does the same without any CLI flag
    captured=$(${wrapperWithForgeDefault}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg s "$forge_socket" '.network.allowUnixSockets | index($s)' >/dev/null \
      || fail "defaultAllowForge=true did not allow the socket. settings=$settings"

    # Coordinator state lives outside ~/.pi, so no session reaches any of it
    # unless its role grants a piece.
    coord_root=$HOME/.local/state/pi-coord
    captured=$(pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg p "$coord_root" \
      '[.filesystem.allowRead, .filesystem.allowWrite] | flatten | map(select(startswith($p))) | length == 0' >/dev/null \
      || fail "a plain session reaches coordinator state. settings=$settings"

    # A build with no broker cannot spawn anything, so it refuses rather than
    # starting a coordinator whose every spawn_agent would hang.
    if captured=$(pi --coordinator -- x 2>&1); then
      fail "--coordinator ran without a broker. captured=$captured"
    fi
    echo "$captured" | grep -q "no pi-broker" \
      || fail "--coordinator refusal missing diagnostic. captured=$captured"

    # The coordinator writes requests and nothing else there, and reads what
    # its broker and children record.
    captured=$(${wrapperWithBroker}/bin/pi --coordinator=test-1 -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    cdir=$coord_root/test-1
    echo "$captured" | grep -q "PI_PLAN_BROKER: ${stubBroker}/bin/pi-broker $cdir " \
      || fail "--coordinator did not plan the broker for $cdir. captured=$captured"
    # envVars blanks TMUX for pi, and the broker still joins the caller's session.
    captured=$(TMUX=/tmp/tmux-test/default,1,0 ${wrapperWithBroker}/bin/pi --coordinator=test-1 -- x 2>&1)
    echo "$captured" | grep -qx "PI_PLAN_BROKER_TMUX: /tmp/tmux-test/default,1,0" \
      || fail "broker did not get the caller's TMUX. captured=$captured"
    echo "$captured" | grep -qx "PI_PLAN_EXPORTED: TMUX=" \
      || fail "pi did not get the envVars TMUX. captured=$captured"
    echo "$captured" | grep -q "PI_PLAN_GRANTS: coordinator" \
      || fail "--coordinator missing PI_PLAN_GRANTS. captured=$captured"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: PI_COORD_DIR=$cdir" \
      || fail "--coordinator did not export PI_COORD_DIR. captured=$captured"
    echo "$settings" | jq -e --arg p "$cdir" '.filesystem.allowRead | index($p)' >/dev/null \
      || fail "coordinator cannot read its own state. settings=$settings"
    echo "$settings" | jq -e --arg p "$coord_root" --arg r "$cdir/requests" \
      '.filesystem.allowWrite | map(select(startswith($p))) == [$r]' >/dev/null \
      || fail "coordinator writes more than its requests dir. settings=$settings"
    # A generated id satisfies the same pattern a given one must.
    captured=$(${wrapperWithBroker}/bin/pi --coordinator -- x 2>&1)
    echo "$captured" | grep -qE "PI_PLAN_BROKER: [^ ]+ $coord_root/[0-9]{4}-[0-9]{4}-[0-9a-f]{4} " \
      || fail "--coordinator did not generate a well-formed id. captured=$captured"
    if captured=$(${wrapperWithBroker}/bin/pi --coordinator=../escape -- x 2>&1); then
      fail "--coordinator accepted an id that climbs out of its root. captured=$captured"
    fi

    # A child writes only its own agent dir: not requests, so it cannot spawn,
    # and not a sibling's result or the broker's state.
    captured=$(pi --coord-child=test-1/agent-a -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    adir=$cdir/agents/agent-a
    echo "$settings" | jq -e --arg p "$coord_root" --arg a "$adir" \
      '(.filesystem.allowWrite | map(select(startswith($p))) == [$a])
       and (.filesystem.allowRead | map(select(startswith($p))) == [$a])' >/dev/null \
      || fail "child reaches more of the coordinator than its agent dir. settings=$settings"
    echo "$captured" | grep -q "PI_PLAN_GRANTS: coord-child" \
      || fail "--coord-child missing PI_PLAN_GRANTS. captured=$captured"
    for bad in "test-1/../../x" "test-1/" "../x/agent-a" "test-1/Agent"; do
      if captured=$(pi --coord-child="$bad" -- x 2>&1); then
        fail "--coord-child=$bad was accepted. captured=$captured"
      fi
    done

    # --allow-ssh-agent grants the agent socket plus the three ssh files that
    # make it usable. What it must NOT grant is the private key or the
    # directory holding it: signing through the agent instead of from disk is
    # the entire reason this grant exists, so the negative assertions below are
    # the load-bearing ones.
    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/config" "$HOME/.ssh/known_hosts" \
      "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519.pub"
    ssh_sock=$HOME/.ssh/agent-test.sock

    captured=$(SSH_AUTH_SOCK=$ssh_sock pi --allow-ssh-agent -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$captured" | grep -q "PI_PLAN_GRANTS: ssh-agent" \
      || fail "--allow-ssh-agent missing PI_PLAN_GRANTS. captured=$captured"
    # Composed grants comma-join in argument order; that string is what
    # extensions/grants.ts splits. Not reusing $captured, whose ssh-agent
    # value $settings below still depends on.
    composed=$(SSH_AUTH_SOCK=$ssh_sock pi --allow-nix --allow-ssh-agent -- x 2>&1)
    echo "$composed" | grep -q "PI_PLAN_GRANTS: nix,ssh-agent" \
      || fail "composed grants not recorded as 'nix,ssh-agent'. captured=$composed"
    echo "$settings" | jq -e --arg s "$ssh_sock" '.network.allowUnixSockets | index($s)' >/dev/null \
      || fail "--allow-ssh-agent did not allow the agent socket. settings=$settings"
    echo "$settings" | jq -e --arg s "$ssh_sock" '.filesystem.allowRead | index($s)' >/dev/null \
      || fail "--allow-ssh-agent left the socket path unreadable. settings=$settings"
    # The public key is not decoration: IdentitiesOnly=yes picks which agent
    # key to offer by matching against it, so ssh fails without it.
    for f in config known_hosts id_ed25519.pub; do
      echo "$settings" | jq -e --arg f "$HOME/.ssh/$f" '.filesystem.allowRead | index($f)' >/dev/null \
        || fail "--allow-ssh-agent did not grant $f. settings=$settings"
    done
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$HOME/.ssh/id_ed25519\")" >/dev/null \
      && fail "--allow-ssh-agent exposed a private key. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$HOME/.ssh\")" >/dev/null \
      && fail "--allow-ssh-agent granted all of ~/.ssh. settings=$settings"

    # No agent is a refusal. Granting nothing and carrying on would surface
    # much later as an opaque "Permission denied (publickey)" from ssh.
    if captured=$(unset SSH_AUTH_SOCK; pi --allow-ssh-agent -- x 2>&1); then
      fail "--allow-ssh-agent granted with no agent. captured=$captured"
    fi
    echo "$captured" | grep -q "SSH_AUTH_SOCK is unset" \
      || fail "refusal did not name the missing agent. captured=$captured"

    # An agent in the environment grants nothing on its own
    captured=$(SSH_AUTH_SOCK=$ssh_sock pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg s "$ssh_sock" '.network.allowUnixSockets | index($s)' >/dev/null \
      && fail "agent socket granted without the flag. settings=$settings"
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$HOME/.ssh/config\")" >/dev/null \
      && fail "ssh config granted without the flag. settings=$settings"

    # All three socket grants at once, exercising the list rather than a
    # single-element shortcut
    captured=$(SSH_AUTH_SOCK=$ssh_sock pi --allow-nix --allow-forge --allow-ssh-agent -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --argjson n "$((nix_sock_count + 2))" \
      '.network.allowUnixSockets | length == $n' >/dev/null \
      || fail "three grants did not yield three sockets. settings=$settings"

    # defaultAllowSshAgent=true does the same without any CLI flag
    captured=$(SSH_AUTH_SOCK=$ssh_sock ${wrapperWithSshAgentDefault}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg s "$ssh_sock" '.network.allowUnixSockets | index($s)' >/dev/null \
      || fail "defaultAllowSshAgent=true did not allow the socket. settings=$settings"

    # --allow-forge grants the kubeconfig forge writes, plus the loopback
    # egress its API servers need. srt gates that behind allowLocalBinding
    # rather than the domain allowlist, so the read alone would be a grant that
    # cannot connect.
    forge_kubeconfig=$HOME/.local/state/forge/kubeconfig.yaml
    captured=$(pi --allow-forge -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg k "$forge_kubeconfig" '.filesystem.allowRead | index($k)' >/dev/null \
      || fail "--allow-forge did not grant the kubeconfig. settings=$settings"
    echo "$settings" | jq -e '.network.allowLocalBinding == true' >/dev/null \
      || fail "--allow-forge left loopback egress closed. settings=$settings"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: KUBECONFIG=$forge_kubeconfig" \
      || fail "--allow-forge did not point KUBECONFIG at the grant. captured=$captured"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: KUBECACHEDIR=$HOME/.pi/sandbox-cache/kube" \
      || fail "--allow-forge did not redirect the discovery cache. captured=$captured"

    # ~/.kube holds real cluster credentials and credentialMasks covers it. This
    # grant is one file outside it, and must not reopen the directory.
    echo "$settings" | jq -e ".filesystem.allowRead | index(\"$HOME/.kube\")" >/dev/null \
      && fail "--allow-forge re-allowed ~/.kube. settings=$settings"

    # Not taken from the environment, for the reason DOCKER_HOST is not: it
    # becomes an allowRead entry, so a checkout's .envrc must not choose it.
    captured=$(FORGE_KUBECONFIG=/Users/nobody/.ssh/id_ed25519 pi --allow-forge -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.filesystem.allowRead | index("/Users/nobody/.ssh/id_ed25519")' >/dev/null \
      && fail "FORGE_KUBECONFIG chose a granted read path. settings=$settings"

    # Bounded by the same VM as the socket: cluster-admin on a cluster inside it
    # is a privileged pod away from root in a node container, so a mounted host
    # path would be reachable that way too.
    mk_instance '[{"location":"~","writable":true}]' "$deny_pair"
    if captured=$(pi --allow-forge -- x 2>&1); then
      fail "--allow-forge granted on a VM mounting \$HOME. captured=$captured"
    fi
    echo "$captured" | grep -q -- "--allow-forge: instance" \
      || fail "refusal did not name the flag. captured=$captured"
    mk_instance '[]' "$deny_pair"

    # Without the flag, neither the path nor the loopback opening
    captured=$(pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg k "$forge_kubeconfig" '.filesystem.allowRead | index($k)' >/dev/null \
      && fail "kubeconfig granted without the flag. settings=$settings"
    echo "$captured" | grep -q "PI_PLAN_HARDENING: KUBECONFIG=" \
      && fail "KUBECONFIG set without the grant. captured=$captured"

    # defaultAllowForge=true does the same without any CLI flag
    captured=$(${wrapperWithForgeDefault}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e --arg k "$forge_kubeconfig" '.filesystem.allowRead | index($k)' >/dev/null \
      || fail "defaultAllowForge=true did not grant the kubeconfig. settings=$settings"
    # and records it, or grants.ts would list forge as missing
    echo "$captured" | grep -q "PI_PLAN_GRANTS: forge" \
      || fail "defaultAllowForge=true missing from PI_PLAN_GRANTS. captured=$captured"

    # defaultWritePaths reaches allowWrite, with ~ expanded
    captured=$(${wrapperWithWritePaths}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e ".filesystem.allowWrite | index(\"$HOME/.kube/configs\")" >/dev/null \
      || fail "defaultWritePaths did not reach allowWrite. settings=$settings"

    # TMPDIR is redirected into the write grant; no inherited temp dir is in it
    captured=$(pi -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_HARDENING: TMPDIR=$HOME/.pi/sandbox-cache/tmp" \
      || fail "TMPDIR not redirected under the cache root. captured=$captured"

    # HotSpot on darwin reads the Darwin per-user temp dir rather than TMPDIR,
    # so the line above never reaches java.io.tmpdir and a jar unpacking a
    # native library (sqlite-jdbc) dies on the lock file it writes there.
    echo "$captured" \
      | grep -q "PI_PLAN_HARDENING: JAVA_TOOL_OPTIONS=-Djava.io.tmpdir=$HOME/.pi/sandbox-cache/tmp" \
      || fail "java.io.tmpdir not redirected under the cache root. captured=$captured"
    # Without this an AWT init hangs on the window server rather than failing.
    echo "$captured" | grep -q "PI_PLAN_HARDENING: JAVA_TOOL_OPTIONS=.*-Djava.awt.headless=true" \
      || fail "AWT not forced headless. captured=$captured"
    # Loopback binding is IPv4-only while localhost resolves to ::1 first, so
    # a JVM test server and its client land on different stacks.
    echo "$captured" \
      | grep -q "PI_PLAN_HARDENING: JAVA_TOOL_OPTIONS=.*-Djava.net.preferIPv4Stack=true" \
      || fail "JVM not pinned to IPv4. captured=$captured"

    # Seats: each seat the caller leaves empty comes from the seats file, and
    # only seat names are exported from it.
    printf '%s\n' \
      '# what the session is for' \
      'PI_SESSION_MODEL=fakecloud/acme/zeta-9000:high' \
      'PI_AGENT_MODEL_CRITIC=fakecloud/acme/omega-2' \
      'NOT_A_SEAT=fakecloud/acme/x' \
      'PATH=/nowhere' \
      'PI_SPAWN_MODEL=has a space' \
      >"$HOME/seats"
    seats=${wrapperWithSeats}/bin/pi
    captured=$($seats -- x 2>&1) || fail "seats: refused a trusted seat. captured=$captured"
    for v in PI_SESSION_MODEL PI_AGENT_MODEL_CRITIC; do
      echo "$captured" | grep -qx "PI_PLAN_SEAT: $v" || fail "seats: $v not loaded. captured=$captured"
    done
    for v in NOT_A_SEAT PATH PI_SPAWN_MODEL; do
      echo "$captured" | grep -q "PI_PLAN_SEAT: $v" && fail "seats: loaded $v. captured=$captured"
    done
    echo "$captured" | grep -q "PI_PLAN_EXEC.*--model fakecloud/acme/zeta-9000:high x" \
      || fail "seats: session seat not passed as --model. captured=$captured"
    echo "$captured" | grep -qx "PI_PLAN_SESSION: fakecloud/acme/zeta-9000:high" \
      || fail "seats: PI_SESSION_MODEL not exported. captured=$captured"
    echo "$captured" | grep -qx "PI_PLAN_TRUSTED: fakecloud" \
      || fail "seats: PI_TRUSTED_PROVIDERS not exported. captured=$captured"

    # The caller's env wins over the file, and empty counts as unset.
    captured=$(PI_AGENT_MODEL_CRITIC=fakecloud/acme/other $seats -- x 2>&1)
    echo "$captured" | grep -q "PI_PLAN_SEAT: PI_AGENT_MODEL_CRITIC" \
      && fail "seats: file beat the caller's env. captured=$captured"
    captured=$(PI_AGENT_MODEL_CRITIC= $seats -- x 2>&1)
    echo "$captured" | grep -qx "PI_PLAN_SEAT: PI_AGENT_MODEL_CRITIC" \
      || fail "seats: an empty caller value blocked the file's. captured=$captured"

    # --model beats the session seat, which then adds no second --model.
    captured=$($seats --model fakecloud/acme/b -- x 2>&1)
    [ "$(echo "$captured" | grep -o -- '--model' | wc -l)" -eq 1 ] \
      || fail "seats: --model given, seat added another. captured=$captured"
    echo "$captured" | grep -qx "PI_PLAN_SESSION: fakecloud/acme/b" \
      || fail "seats: PI_SESSION_MODEL is not the --model in force. captured=$captured"
    captured=$($seats --provider fakecloud --model acme/c -- x 2>&1) \
      || fail "seats: --provider with a trusted name refused. captured=$captured"
    echo "$captured" | grep -qx "PI_PLAN_SESSION: fakecloud/acme/c" \
      || fail "seats: --provider not folded into the session. captured=$captured"
    # A --model after pi's own -- is a message, not a flag. (The wrapper
    # consumes the first --, which ends its own flags.)
    captured=$($seats --print -- --model othercloud/acme/x 2>&1) \
      || fail "seats: a message after -- was read as --model. captured=$captured"

    # Untrusted, unqualified or missing: refused, naming no id.
    if captured=$($seats --model othercloud/acme/secret-1 -- x 2>&1); then
      fail "seats: started on an untrusted provider. captured=$captured"
    fi
    echo "$captured" | grep -q "provider 'othercloud' is not in trustedProviders (fakecloud)" \
      || fail "seats: refusal does not name the provider. captured=$captured"
    echo "$captured" | grep -q "secret-1" && fail "seats: refusal printed the id. captured=$captured"
    echo "$captured" | grep -q "PI_PLAN_EXEC" && fail "seats: refused but still planned exec. captured=$captured"
    if captured=$($seats --model zeta-9000 -- x 2>&1); then
      fail "seats: started on a --model with no provider. captured=$captured"
    fi
    mv "$HOME/seats" "$HOME/seats.off"
    if captured=$($seats -- x 2>&1); then
      fail "seats: started with no session model. captured=$captured"
    fi
    echo "$captured" | grep -q "no session model" || fail "seats: wrong refusal. captured=$captured"
    echo "$captured" | grep -q "seats file $HOME/seats does not exist" \
      || fail "seats: a missing seats file not named. captured=$captured"
    echo "$captured" | grep -q "this host's sops file" \
      || fail "seats: refusal does not say where to fix it. captured=$captured"
    printf 'PI_AGENT_MODEL_CRITIC=fakecloud/acme/omega-2\n' >"$HOME/seats"
    if captured=$($seats -- x 2>&1); then
      fail "seats: started with no PI_SESSION_MODEL line. captured=$captured"
    fi
    echo "$captured" | grep -q "Add a PI_SESSION_MODEL=provider/id\[:level\] line to pi_seats" \
      || fail "seats: no fix for a missing session line. captured=$captured"
    mv "$HOME/seats.off" "$HOME/seats"

    # An unreadable seats file is a refusal that names its owner, not a
    # silent "no seats".
    chmod 000 "$HOME/seats"
    if [ ! -r "$HOME/seats" ]; then
      if captured=$($seats --model fakecloud/acme/b -- x 2>&1); then
        fail "seats: started with an unreadable seats file. captured=$captured"
      fi
      echo "$captured" | grep -q "needs owner = " \
        || fail "seats: unreadable seats file without the owner fix. captured=$captured"
    fi
    chmod 600 "$HOME/seats"

    # A wrapper with no trust list refuses nothing.
    pi --model othercloud/acme/x -- x >/dev/null 2>&1 || fail "no trust list, yet a provider was refused"

    # The check runs before every start, requires the advisor seat under
    # --advisor, and a failure stops the start.
    captured=$(${wrapperWithSeatsCheck}/bin/pi --advisor -- x 2>&1)
    echo "$captured" | grep -qx "SEATS_CHECK check --start --require PI_ADVISOR_MODEL" \
      || fail "seats check: not run, or --advisor not required. captured=$captured"
    touch "$HOME/fail-seats-check"
    if captured=$(${wrapperWithSeatsCheck}/bin/pi -- x 2>&1); then
      fail "seats check: failed, yet pi started. captured=$captured"
    fi
    rm "$HOME/fail-seats-check"

    # models.json read grant: every link on the way and the file, canonical,
    # and never a directory. The links mirror a home-manager store link, then
    # /run/secrets, then the generation directory.
    C=$(cd "$TMPDIR" && pwd -P)/chain
    mkdir -p "$C/secrets.d/1" "$HOME/.pi/agent"
    echo '{}' >"$C/secrets.d/1/pi_models_json"
    echo 'other secret' >"$C/secrets.d/1/sibling"
    ln -s secrets.d/1 "$C/secrets"
    ln -s "$C/secrets/pi_models_json" "$C/store-link"
    ln -sfn "$C/store-link" "$HOME/.pi/agent/models.json"
    H=$(cd "$HOME" && pwd -P)
    captured=$(pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    for node in "$H/.pi/agent/models.json" "$C/store-link" "$C/secrets" "$C/secrets.d/1/pi_models_json"; do
      echo "$settings" | jq -e --arg p "$node" '.filesystem.allowRead | index($p)' >/dev/null \
        || fail "models.json chain: $node not granted. settings=$settings"
    done
    for dir in "$C/secrets.d/1" "$C/secrets.d" "$C"; do
      echo "$settings" | jq -e --arg p "$dir" '.filesystem.allowRead | index($p) | not' >/dev/null \
        || fail "models.json chain: granted the directory $dir. settings=$settings"
    done
    rm "$HOME/.pi/agent/models.json"

    # Each trusted provider's endpoint comes from the catalog, and only through
    # home-manager's link into the store: no untrusted provider's, no
    # loopback, and nothing from a plain file a session could have written.
    ln -s ${catalogInStore} "$HOME/.pi/agent/models.json"
    captured=$(PI_SESSION_MODEL=fakecloud/acme/zeta-9000 ${wrapperWithCatalog}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowedDomains == ["gw.fakecloud.test"]' >/dev/null \
      || fail "catalog endpoints: want the trusted, non-loopback host alone. settings=$settings"
    # Endpoints are private, and PI_ALLOWED_HOSTS is shown in the footer.
    if echo "$captured" | grep -q "PI_PLAN_ALLOWED_HOSTS"; then
      fail "catalog endpoints: a provider host reached PI_ALLOWED_HOSTS. captured=$captured"
    fi
    rm "$HOME/.pi/agent/models.json"
    cp ${catalogInStore} "$HOME/.pi/agent/models.json"
    captured=$(PI_SESSION_MODEL=fakecloud/acme/zeta-9000 ${wrapperWithCatalog}/bin/pi -- x 2>&1)
    settings=$(echo "$captured" | sed -n 's/^PI_PLAN_SETTINGS: //p')
    echo "$settings" | jq -e '.network.allowedDomains == []' >/dev/null \
      || fail "catalog endpoints: trusted a plain file. settings=$settings"
    echo "$captured" | grep -q "allows no provider endpoint" \
      || fail "catalog endpoints: no warning for a plain file. captured=$captured"
    rm -f "$HOME/.pi/agent/models.json"

    touch $out
  ''
