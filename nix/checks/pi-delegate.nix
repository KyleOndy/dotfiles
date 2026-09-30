# Flake check that drives pi-delegate (nix/pkgs/pi-delegate) against a stub
# pi: a clean run, pi exiting 0 without running the agent, a final reply that
# is an error after retries, a crash, a timeout, a killed pi, following a run
# that already finished, refused names, briefs that look like flags, an
# --edit worktree and a --tmux window.
#
# pi and tmux are stubs; git, the worktree script, the detached runner and
# the follower are real. The stub picks its behavior from the brief's first
# word and records its arguments.
{ pkgs }:
pkgs.runCommand "pi-delegate-check"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.jq
      pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail
    T=$TMPDIR/t
    export HOME=$T/home
    unset TMUX XDG_STATE_HOME PI_DELEGATE_MODEL PI_DELEGATE_TIMEOUT PI_DELEGATE_TMUX
    STATE=$HOME/.local/state/pi-delegate
    mkdir -p "$HOME" "$T/stubs"
    fail() {
      echo "FAIL: $*" >&2
      for d in "$STATE"/*; do echo "== $d" >&2; tail -n 5 "$d"/* >&2 || true; done
      exit 1
    }

    cat >"$T/stubs/pi" <<EOF
    #!${pkgs.runtimeShell}
    printf '%s\n' "\$@" >"$T/args"
    brief="\''${@: -1}"
    ev() { printf '%s\n' "\$1"; sleep 0.1; }
    ev '{"type":"session"}'
    case "\''${brief%% *}" in
    noagent) exit 0 ;;
    crash) echo boom >&2; exit 3 ;;
    hang) exec sleep 600 ;;
    die) echo \$\$ >"$T/pi.pid"; exec sleep 600 ;;
    error)
      ev '{"type":"agent_start"}'
      ev '{"type":"auto_retry_start","attempt":1,"maxAttempts":2,"errorMessage":"503: no endpoints"}'
      ev '{"type":"agent_end","messages":[{"role":"assistant","stopReason":"error","errorMessage":"503: no endpoints","content":[]}]}'
      exit 0 ;;
    esac
    [ "\''${brief%% *}" = write ] && echo hi >made.txt
    ev '{"type":"agent_start"}'
    ev '{"type":"tool_execution_start","toolName":"read","args":{"path":"a.nix"}}'
    ev '{"type":"message_end","message":{"role":"assistant","usage":{"totalTokens":10,"cost":{"total":0.25}}}}'
    ev '{"type":"tool_execution_start","toolName":"grep","args":{"pattern":"x"}}'
    ev '{"type":"message_end","message":{"role":"assistant","usage":{"totalTokens":20,"cost":{"total":0.5}}}}'
    # The last event lands right before exit, where a follower that stops on
    # the exit file can miss it.
    printf '%s\n' '{"type":"agent_end","messages":[{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"the answer"}]}]}'
    EOF
    # new-window -d -n <name> -c <dir> -- <cmd...>: run it detached in <dir>.
    cat >"$T/stubs/tmux" <<EOF
    #!${pkgs.runtimeShell}
    echo "tmux \$*" >>"$T/calls"
    shift 4; dir="\$2"; shift 3
    (cd "\$dir" && "\$@" </dev/null >/dev/null 2>&1) &
    EOF
    chmod +x "$T/stubs/"*
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

    pd 0 --name ok "ok go"
    has "tool: read {\"path\":\"a.nix\"}"
    has "tool: grep"
    has "DONE tokens=30 cost=0.75"
    has "the answer"
    [ "$(tail -n 1 "$T/out")" = "the answer" ] || fail "result is not last: $(cat "$T/out")"
    grep -qx "read,grep,find,ls" "$T/args" || fail "read-only run got other tools: $(cat "$T/args")"
    grep -qx -- "--no-approve" "$T/args" || fail "pi ran without --no-approve"
    [ "$(cat "$STATE/ok/exit")" = 0 ] || fail "exit file holds $(cat "$STATE/ok/exit")"

    grep -v '^run: ' "$T/out" >"$T/first"
    pd 0 follow ok
    cmp -s "$T/out" "$T/first" || fail "follow after the run differs: $(diff "$T/first" "$T/out")"

    pd 1 --name noagent "noagent"
    has "FAILED exit=1"
    has "pi never ran the agent"

    pd 1 --name error "error"
    has "retry: 1/2 503: no endpoints"
    has "FAILED exit=1"
    has "503: no endpoints"

    pd 3 --name crash "crash"
    has "FAILED exit=3"
    has "boom"

    PI_DELEGATE_TIMEOUT=1s pd 124 --name hang "hang"
    has "FAILED exit=124"

    ( for _ in $(seq 100); do [ -s "$T/pi.pid" ] && break; sleep 0.1; done
      kill "$(cat "$T/pi.pid")" ) &
    pd 143 --name die "die"
    has "FAILED exit=143"

    pd 2 --name ok "again"
    has "already exists"
    pd 2 --name Bad "x"
    has "name must be"
    pd 2 --name ../up "x"
    [ ! -e "$HOME/.local/state/up" ] || fail "a name escaped the state dir"

    printf -- '--version is the brief\n' | pd 0 --name stdin -
    [ "$(tail -n 1 "$T/args")" = "--version is the brief" ] || fail "stdin brief arrived as $(tail -n 1 "$T/args")"
    pd 0 --name dash -- "-x brief"
    [ "$(tail -n 1 "$T/args")" = "-x brief" ] || fail "dash brief arrived as $(tail -n 1 "$T/args")"

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
    has "DONE tokens=30"

    touch "$out"
  ''
