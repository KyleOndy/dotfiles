# Flake check that drives pi-delegate (nix/pkgs/pi-delegate) against a stub
# pi in RPC mode: a clean turn, a second turn by `send`, a steer joining a turn
# in progress, idle close, `stop` mid-turn, a cancelled dialog, a rejected
# brief, pi exiting 0 without running the agent, an errored final reply, a
# crash, a timeout, a killed pi, refused names, briefs that look like flags,
# an --edit worktree and a --tmux window.
#
# pi and tmux are stubs; git, the worktree script, the detached runner, the
# supervisor and the followers are real.
{ pkgs }:
let
  stub = pkgs.writeShellScript "pi" (builtins.readFile ./pi-delegate-stub.sh);
in
pkgs.runCommand "pi-delegate-check"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.jq
      pkgs.coreutils
      pkgs.gawk
    ];
  }
  ''
    set -euo pipefail
    T=$TMPDIR/t
    export HOME=$T/home PI_STUB_DIR=$T PI_DELEGATE_IDLE=5
    unset TMUX XDG_STATE_HOME PI_DELEGATE_MODEL PI_DELEGATE_TIMEOUT PI_DELEGATE_TMUX
    STATE=$HOME/.local/state/pi-delegate
    mkdir -p "$HOME" "$T/stubs"
    # Runs left open would outlive the build.
    cleanup() {
      for d in "$STATE"/*/; do
        [ -e "$d/exit" ] || "$T/pd" stop "$(basename "$d")" >/dev/null 2>&1 || true
      done
    }
    trap cleanup EXIT
    fail() {
      echo "FAIL: $*" >&2
      for d in "$STATE"/*; do echo "== $d" >&2; tail -n 5 "$d"/*.ndjson "$d"/stderr.log >&2 || true; done
      exit 1
    }

    ln -s ${stub} "$T/stubs/pi"
    # new-window -d -n <name> -c <dir> -- <cmd...>: run it detached in <dir>.
    cat >"$T/stubs/tmux" <<EOF
    #!${pkgs.runtimeShell}
    echo "tmux \$*" >>"$T/calls"
    shift 4; dir="\$2"; shift 3
    (cd "\$dir" && "\$@" </dev/null >/dev/null 2>&1) &
    EOF
    chmod +x "$T/stubs/tmux"
    # The script's own PATH export puts the real tmux first.
    sed "s|^export PATH=\"|export PATH=\"$T/stubs:|" ${pkgs.pi-delegate}/bin/pi-delegate >"$T/pd"
    chmod +x "$T/pd"

    git init -q -b main "$T/seed"
    git -C "$T/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    mkdir "$T/repo"
    git clone -q --bare "$T/seed" "$T/repo/.bare"
    echo "gitdir: ./.bare" >"$T/repo/.git"
    git -C "$T/repo" worktree add -q "$T/repo/main" main
    cd "$T/repo/main"

    # $1 expected status; the rest are pi-delegate's arguments. Output in $T/out.
    pd() {
      local want=$1 got=0
      shift
      timeout 60 "$T/pd" "$@" >"$T/out" 2>&1 || got=$?
      [ "$got" = "$want" ] || fail "pi-delegate $*: exit $got, want $want: $(cat "$T/out")"
    }
    has() { grep -qF -- "$1" "$T/out" || fail "output lacks '$1': $(cat "$T/out")"; }
    lacks() { ! grep -qF -- "$1" "$T/out" || fail "output has '$1': $(cat "$T/out")"; }
    tools() { [ "$(grep -c '^tool: ' "$T/out")" = "$1" ] || fail "want $1 tool lines: $(cat "$T/out")"; }
    # $1 run, $2 a string its events must come to hold.
    wait_for() {
      for _ in $(seq 100); do grep -qF -- "$2" "$STATE/$1/events.ndjson" && return; sleep 0.1; done
      fail "$1 never emitted $2"
    }
    wait_exit() {
      for _ in $(seq 100); do [ -e "$STATE/$1/exit" ] && return; sleep 0.1; done
      fail "$1 never exited"
    }

    pd 0 --name ok "ok go"
    tools 2
    has "tool: read {\"path\":\"a.nix\"}"
    has "DONE turn=1 tokens=30 cost=0.75"
    has "the answer 1"
    has "open: pi-delegate send ok <message>"
    grep -qx "rpc" "$T/args" || fail "pi ran outside RPC mode: $(cat "$T/args")"
    grep -qx "read,grep,find,ls" "$T/args" || fail "read-only run got other tools: $(cat "$T/args")"
    grep -qx -- "--no-approve" "$T/args" || fail "pi ran without --no-approve"
    head -n 1 "$T/cmds" | jq -e '.type == "prompt" and .id == "brief" and .message == "ok go\n"' >/dev/null \
      || fail "the brief went in as $(head -n 1 "$T/cmds")"

    grep -v '^run: ' "$T/out" >"$T/first"
    pd 0 follow ok
    cmp -s "$T/out" "$T/first" || fail "follow after the turn differs: $(diff "$T/first" "$T/out")"

    pd 0 send ok "ok again"
    tools 2
    has "DONE turn=2 tokens=30"
    has "the answer 2"
    lacks "the answer 1"
    pd 0 follow ok
    has "DONE turn=2"

    pd 0 ls
    awk -F'\t' '$1 == "ok" && $2 == "open" && $3 == "turns=2" {f = 1} END {exit !f}' "$T/out" \
      || fail "ls: $(cat "$T/out")"

    pd 0 stop ok
    has "stopped ok exit=0"
    pd 2 send ok "ok more"
    has "has ended"

    PI_DELEGATE_IDLE=1 pd 0 --name idle "ok"
    wait_exit idle
    [ "$(cat "$STATE/idle/exit")" = 0 ] || fail "idle close exited $(cat "$STATE/idle/exit")"

    timeout 60 "$T/pd" --name slow "slow" >"$T/slow.out" 2>&1 &
    bg=$!
    wait_for slow '"type":"agent_start"'
    pd 0 stop slow
    has "stopped slow exit=0"
    st=0
    wait "$bg" || st=$?
    [ "$st" = 1 ] || fail "the aborted turn's waiter exited $st: $(cat "$T/slow.out")"
    grep -q "FAILED turn=1 exit=1" "$T/slow.out" && grep -q aborted "$T/slow.out" \
      || fail "aborted turn: $(cat "$T/slow.out")"

    timeout 60 "$T/pd" --name steer "slow" >"$T/steer.out" 2>&1 &
    bg=$!
    wait_for steer '"type":"agent_start"'
    pd 0 send steer "ok steer"
    has "DONE turn=1"
    wait "$bg" || fail "the steered turn's first waiter failed: $(cat "$T/steer.out")"
    grep -q "DONE turn=1" "$T/steer.out" || fail "steered turn: $(cat "$T/steer.out")"

    rm -f "$T/cmds"
    pd 0 --name ui "ui"
    has "ui: confirm Allow? (cancelled)"
    has "DONE turn=1"
    grep -q '"type":"extension_ui_response","id":"d1","cancelled":true' "$T/cmds" \
      || fail "the dialog was not cancelled: $(cat "$T/cmds")"

    pd 1 --name reject "reject"
    has "rejected: prompt nope"
    has "FAILED turn=1 exit=1"

    pd 1 --name noagent "noagent"
    has "FAILED turn=1 exit=1"
    has "pi exited before turn 1 settled"

    pd 1 --name error "error"
    has "retry: 1/2 503: no endpoints"
    has "FAILED turn=1 exit=1"
    has "503: no endpoints"

    pd 3 --name crash "crash"
    has "FAILED turn=1 exit=3"
    has "boom"

    PI_DELEGATE_TIMEOUT=1s pd 124 --name hang "hang"
    has "FAILED turn=1 exit=124"

    rm -f "$T/pi.pid"
    ( for _ in $(seq 100); do [ -s "$T/pi.pid" ] && break; sleep 0.1; done
      kill "$(cat "$T/pi.pid")" ) &
    pd 143 --name die "die"
    has "FAILED turn=1 exit=143"

    pd 2 --name idle "again"
    has "already exists"
    pd 2 --name Bad "x"
    has "name must be"
    pd 2 --name ../up "x"
    [ ! -e "$HOME/.local/state/up" ] || fail "a name escaped the state dir"

    rm -f "$T/cmds"
    printf -- '--version is the brief\n' | pd 0 --name stdin -
    head -n 1 "$T/cmds" | jq -e '.message == "--version is the brief\n"' >/dev/null \
      || fail "stdin brief arrived as $(head -n 1 "$T/cmds")"
    rm -f "$T/cmds"
    pd 0 --name dash -- "-x brief"
    head -n 1 "$T/cmds" | jq -e '.message == "-x brief\n"' >/dev/null \
      || fail "dash brief arrived as $(head -n 1 "$T/cmds")"

    pd 0 --edit --name ed "write it"
    wt=$T/repo/ed
    [ "$(git -C "$wt" symbolic-ref --short HEAD)" = ed ] || fail "--edit worktree is not on branch ed"
    [ -f "$wt/made.txt" ] || fail "--edit run did not run in its worktree"
    [ ! -e made.txt ] || fail "--edit run wrote to the caller's checkout"
    [ "$(cat "$STATE/ed/base")" = main ] || fail "base is $(cat "$STATE/ed/base")"
    grep -qx "read,grep,find,ls,edit,write,bash" "$T/args" || fail "--edit run lacks edit tools"
    has "?? made.txt"

    pd 0 --tmux --name tm "ok"
    grep -q "^tmux new-window -d -n tm -c $T/repo/main -- " "$T/calls" || fail "tmux call: $(cat "$T/calls")"
    has "DONE turn=1 tokens=30"

    touch "$out"
  ''
