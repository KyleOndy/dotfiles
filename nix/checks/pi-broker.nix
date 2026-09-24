# Flake check that drives pi-broker (nix/pkgs/pi-broker) through a coordinator
# session: spawns, refusals, a child quitting with and without a result,
# teardown and a failed `forge up`.
#
# forge and tmux are stubs, since neither a VM nor a tmux server exists in the
# build sandbox; git, the worktree script and the request protocol are real.
{ pkgs }:
let
  realForge = "${pkgs.forge}/bin/forge";
in
pkgs.runCommand "pi-broker-check"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.jq
      pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail
    fail() {
      echo "FAIL: $*" >&2
      cat "$TMPDIR/e2e/broker.log" "$TMPDIR/e2e/home/.local/state/pi-coord/c1/logs/"* >&2 2>/dev/null || true
      exit 1
    }

    T=$TMPDIR/e2e
    export HOME=$T/home LIMA_HOME=$T/lima
    unset TMUX
    mkdir -p "$HOME/.config/forge" "$LIMA_HOME" "$T/stubs"
    echo 'network: large' >"$HOME/.config/forge/forge.yaml"
    echo 'network: small' >"$HOME/.config/forge/forge-small.yaml"

    # Records every call; `up` makes the VM directory the broker looks for
    # and fails on demand.
    cat >"$T/stubs/forge" <<EOF
    #!${pkgs.runtimeShell}
    echo "forge \$* FORGE_INSTANCE=\''${FORGE_INSTANCE:-} FORGE_CONFIG=\''${FORGE_CONFIG:-}" >>"$T/calls"
    case "\$1" in
    vm-config) exec ${realForge} "\$@" ;;
    up) [ -f "$T/fail-up" ] && exit 1; mkdir -p "\$LIMA_HOME/forge-\$FORGE_INSTANCE" ;;
    nuke) rm -rf "\$LIMA_HOME/forge-\$FORGE_INSTANCE" ;;
    esac
    EOF
    cat >"$T/stubs/tmux" <<EOF
    #!${pkgs.runtimeShell}
    echo "tmux \$*" >>"$T/calls"
    case "\$1" in
    has-session) [ -f "$T/session" ] ;;
    new-session) touch "$T/session" ;;
    new-window) n=\$(( \$(cat "$T/windows" 2>/dev/null | wc -l) + 1 )); echo "@\$n" >>"$T/windows"; echo "@\$n" ;;
    list-windows) cat "$T/windows" 2>/dev/null || true ;;
    kill-window) grep -vxF "\$3" "$T/windows" >"$T/w2" || true; mv "$T/w2" "$T/windows" ;;
    esac
    EOF
    chmod +x "$T/stubs/"*

    # The broker's own PATH export puts the real forge and tmux first.
    sed "s|^export PATH=\"|export PATH=\"$T/stubs:|" ${pkgs.pi-broker}/bin/pi-broker >"$T/broker"
    chmod +x "$T/broker"

    git init -q -b main "$T/seed"
    git -C "$T/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    mkdir "$T/repo"
    git clone -q --bare "$T/seed" "$T/repo/.bare"
    echo "gitdir: ./.bare" >"$T/repo/.git"
    git -C "$T/repo" worktree add -q "$T/repo/main" main

    COORD=$HOME/.local/state/pi-coord/c1
    SLOTS=$HOME/.local/state/pi-coord/slots
    mkdir -p "$COORD/requests"
    sleep 600 &
    WATCH=$!
    "$T/broker" "$COORD" "$WATCH" "$T/repo/main" /fake/pi >"$T/broker.log" 2>&1 &
    BROKER=$!
    # The builder waits on every process holding its output, so a failure has
    # to take the watched sleep and the broker down with it.
    trap 'kill $WATCH $BROKER 2>/dev/null || true' EXIT

    # $1 id, $2 JSON, $3 expected ok, $4 a substring of the message.
    req() {
      echo "$2" >"$COORD/requests/.$1.tmp"
      mv "$COORD/requests/.$1.tmp" "$COORD/requests/$1.json"
      expect "$1" "$3" "$4"
    }
    expect() {
      local r=$COORD/responses/$1.json
      for _ in $(seq 100); do [ -f "$r" ] && break; sleep 0.1; done
      [ -f "$r" ] || fail "$1: no response"
      jq -e --argjson ok "$2" --arg m "$3" '.ok == $ok and (.message | contains($m))' "$r" >/dev/null \
        || fail "$1: want ok=$2 containing '$3', got $(cat "$r")"
    }
    st() { jq -r ".$2 // empty" "$COORD/state/$1.json"; }
    wait_state() {
      for _ in $(seq 100); do [ "$(st "$1" state)" = "$2" ] && return; sleep 0.1; done
      fail "$1 never reached $2: $(cat "$COORD/state/$1.json")"
    }
    close_window() {
      grep -vxF "$(st "$1" window)" "$T/windows" >"$T/w2" || true
      mv "$T/w2" "$T/windows"
    }

    req r1 '{"op":"spawn","agent":"alpha","task":"do alpha"}' true "forge instance 1 (small)"
    req r2 '{"op":"spawn","agent":"beta","task":"do beta","size":"large"}' true "forge instance 2 (large)"
    wait_state alpha running
    wait_state beta running

    # Each agent: its own worktree on its own branch, its own instance, a
    # window running the wrapper sandboxed to both, and the brief as a file.
    [ "$(git -C "$T/repo/alpha" symbolic-ref --short HEAD)" = alpha ] \
      || fail "alpha's worktree is not on branch alpha"
    [ "$(cat "$COORD/agents/alpha/task.md")" = "do alpha" ] || fail "task.md does not hold the brief"
    grep -q "forge up --size small FORGE_INSTANCE=1 FORGE_CONFIG=$HOME/.config/forge/forge-small.yaml" "$T/calls" \
      || fail "small did not come up from forge-small.yaml"
    grep -q "forge up --size large FORGE_INSTANCE=2 FORGE_CONFIG=$HOME/.config/forge/forge.yaml" "$T/calls" \
      || fail "large did not come up from forge.yaml"
    grep -qF -- "-c $T/repo/alpha -- /fake/pi --allow-forge=1 --coord-child=c1/alpha --name alpha @$COORD/agents/alpha/task.md" "$T/calls" \
      || fail "alpha's window does not run the wrapper for its own instance. calls: $(grep new-window "$T/calls")"
    [ "$(grep -c 'new-session' "$T/calls")" = 1 ] || fail "made more than one tmux session"

    # Refusals, each before anything is created.
    req r3 '{"op":"spawn","agent":"Bad/Name","task":"x"}' false "agent name must match"
    req r4 '{"op":"spawn","agent":"alpha","task":"dup"}' false "already exists"
    req r5 '{"op":"spawn","agent":"gamma","task":"x","size":"huge"}' false "size must be"
    req r6 '{"op":"spawn","agent":"delta","task":"x","base":"--upload-pack=evil"}' false "is not a commit"
    req r7 '{"op":"nope"}' false "op must be"
    echo 'not json' >"$COORD/requests/r8.json"
    expect r8 false "not a JSON object"
    # The coordinator cannot read $T/secret; a symlink must not make the
    # unsandboxed broker read it on its behalf.
    echo '{"op":"teardown","agent":"leaked-field"}' >"$T/secret"
    ln -s "$T/secret" "$COORD/requests/r9.json"
    expect r9 false "not a regular file"
    grep -q leaked-field "$COORD"/responses/*.json && fail "a symlinked request was read"
    [ -e "$COORD/state/delta.json" ] && fail "a refused spawn left state behind"

    # Budget: 4 + 8 + 8 + 8 = 28 of 32, so a fifth large does not fit.
    req r10 '{"op":"spawn","agent":"eps","task":"x","size":"large"}' true "instance 3"
    req r11 '{"op":"spawn","agent":"zeta","task":"x","size":"large"}' true "instance 4"
    req r12 '{"op":"spawn","agent":"eta","task":"x","size":"large"}' false "28 of 32GiB"

    # A child that quits without reporting, and one that reports first.
    close_window alpha
    wait_state alpha exited
    echo "all good" >"$COORD/agents/beta/result.md"
    close_window beta
    wait_state beta done

    # A child can write its agent dir, so nothing there may steer the broker:
    # a forged instance number must not aim the teardown at a sibling's VM.
    echo '{"instance":"3"}' >"$COORD/agents/alpha/status.json"
    req r13 '{"op":"teardown","agent":"alpha","remove_worktree":true}' true "tearing down"
    wait_state alpha torn-down
    [ -d "$LIMA_HOME/forge-3" ] || fail "tearing down alpha nuked eps's VM"
    [ -d "$LIMA_HOME/forge-1" ] && fail "alpha's VM survived its teardown"
    [ -d "$SLOTS/1" ] && fail "alpha's slot was not released"
    [ -d "$T/repo/alpha" ] && fail "remove_worktree kept a clean worktree"
    git -C "$T/repo" rev-parse --verify --quiet refs/heads/alpha >/dev/null || fail "teardown deleted the branch"
    req r14 '{"op":"teardown","agent":"alpha"}' false "already torn down"

    # Changes in a worktree stop its removal, and the teardown says so.
    echo wip >"$T/repo/beta/wip"
    req r15 '{"op":"teardown","agent":"beta","remove_worktree":true}' true "tearing down"
    wait_state beta torn-down
    [ -d "$T/repo/beta" ] || fail "remove_worktree deleted a worktree with changes"
    st beta error | grep -q "worktree kept" || fail "beta's error does not say the worktree was kept"

    # A failed forge up gives back its VM and slot.
    touch "$T/fail-up"
    req r16 '{"op":"spawn","agent":"theta","task":"x"}' true "instance 1"
    wait_state theta failed
    [ -d "$SLOTS/1" ] && fail "a failed spawn kept its slot"

    # A coordinator on a ticket branch files its agents under that ticket.
    rm "$T/fail-up"
    git -C "$T/repo/main" switch -q -c DEV-7-coordinate
    req r17 '{"op":"spawn","agent":"iota","task":"x"}' true "instance 1"
    wait_state iota running
    [ "$(git -C "$T/repo/DEV-7/iota" symbolic-ref --short HEAD)" = DEV-7-iota ] \
      || fail "iota's worktree is not DEV-7/iota on branch DEV-7-iota"
    [ "$(st iota branch)" = DEV-7-iota ] || fail "iota's state names branch $(st iota branch)"

    kill $WATCH
    wait $BROKER || true
    [ -e "$COORD/broker.pid" ] && fail "broker.pid outlived the broker"
    touch $out
  ''
