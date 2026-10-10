# Flake check for pi-seats (nix/pkgs/pi-seats): every check rule in both
# modes, get's precedence, list, a missing or unreadable seats file, and that
# no check output names a fixture id.
#
# The fixtures use made-up providers and ids. fakecloud is trusted and
# othercloud is not.
{ pkgs }:
let
  pi-seats = pkgs.pi-seats.override {
    seatsFile = "~/seats";
    trustedProviders = [ "fakecloud" ];
  };
in
pkgs.runCommand "pi-seats-check" { nativeBuildInputs = [ pi-seats ]; } ''
  set -euo pipefail
  fail() {
    echo "FAIL: $*" >&2
    cat "$T/out" >&2 2>/dev/null || true
    exit 1
  }
  run() { # <exit> <command...>
    want=$1
    shift
    rc=0
    "$@" >"$T/out" 2>&1 || rc=$?
    [ "$rc" = "$want" ] || fail "$*: exit $rc, wanted $want"
    if grep -qiE 'acme|zeta|omega|kappa|sigma' "$T/out"; then fail "$*: printed a fixture id"; fi
  }
  has() {
    grep -qF -- "$1" "$T/out" || fail "no line: $1"
  }
  quiet() {
    [ ! -s "$T/out" ] || fail "expected no output"
  }
  seats() {
    printf '%s\n' "$@" >"$HOME/seats"
  }
  agent() { # <file> <name> [seat] [needs]
    {
      echo ---
      echo "name: $2"
      echo "description: d"
      [ -z "''${3:-}" ] || echo "seat: $3"
      [ -z "''${4:-}" ] || echo "needs: $4"
      echo ---
      echo body
    } >"$A/agents/$1.md"
  }

  T=$TMPDIR/ps
  export HOME=$T/home
  A=$HOME/.pi/agent
  S=$HOME/seats
  mkdir -p "$A/agents"
  agent critic critic required
  agent vision vision required image
  agent scout scout
  cat >"$A/models.json" <<'EOF'
  {"providers": {
    "fakecloud": {"models": [
      {"id": "acme/zeta-9000", "input": ["text"], "reasoning": true,
       "thinkingLevelMap": {"max": null, "xhigh": "high", "high": "high"}},
      {"id": "acme/omega-2", "input": ["text", "image"], "reasoning": true},
      {"id": "acme/kappa-7", "input": ["text"], "reasoning": false},
      {"id": "acme/sigma-3:beta", "input": ["text"]}
    ]},
    "othercloud": {"models": [{"id": "acme/omega-2", "input": ["text", "image"]}]}
  }}
  EOF

  good=(
    '# a comment, and a blank line'
    ""
    PI_SESSION_MODEL=fakecloud/acme/zeta-9000:xhigh
    PI_ADVISOR_MODEL=fakecloud/acme/omega-2:high
    PI_AGENT_MODEL_CRITIC=fakecloud/acme/omega-2:high
    PI_AGENT_MODEL_VISION=fakecloud/acme/omega-2
    PI_CLASSIFY_MODEL=fakecloud/acme/kappa-7:off
  )
  # deploy fails on every problem; start only on one in the session's own
  # seat, and warns about the rest.
  modes() { # <deploy exit> <start exit>
    run "$1" pi-seats check --deploy
    cp "$T/out" "$T/deploy"
    run "$2" pi-seats check --start
    cp "$T/out" "$T/start"
  }
  both() { # <deploy exit> <start exit> [line]...: modes on the good file, each line replacing its var's or appended
    printf '%s\n' "''${good[@]}" >"$S"
    for line in "''${@:3}"; do
      grep -v "^''${line%%=*}=" "$S" >"$T/seats"
      echo "$line" >>"$T/seats"
      mv "$T/seats" "$S"
    done
    modes "$1" "$2"
  }
  both_have() { # the problem, failing deploy and failing or warning at start
    grep -qF -- "$1" "$T/deploy" || fail "--deploy: no line: $1"
    grep -qF -- "''${1#pi-seats: }" "$T/start" || fail "--start: no line: $1"
  }

  # A good file passes; deploy says so, start says nothing.
  both 0 0
  grep -qxF 'pi-seats: 5 seats ok' "$T/deploy" || fail "no deploy summary"
  [ ! -s "$T/start" ] || fail "--start printed on success"

  # Lines: the shape, by number only.
  both 1 0 'PI_SPAWN_MODEL = fakecloud/acme/omega-2'
  both_have "pi-seats: $S:8: not VAR=value"
  both 1 0 'pi_spawn_model=fakecloud/acme/omega-2'
  both_have "pi-seats: $S:8: not VAR=value"
  both 1 0 'PI_SPAWN_MODEL=fakecloud/acme/omega-2 '
  both_have "pi-seats: $S:8: not VAR=value"
  both 1 0 '  # an indented comment'
  both_have "pi-seats: $S:8: not VAR=value"
  both 0 0 'PI_AGENT_MODEL_SCOUT=fakecloud/acme/omega-2:low'

  # Lines: a known seat, once.
  both 1 0 'PI_AGENT_MODEL_CRTIC=fakecloud/acme/omega-2'
  both_have "pi-seats: PI_AGENT_MODEL_CRTIC ($S:8): not a seat"
  both 1 0 'FOO=bar'
  both_have "pi-seats: FOO ($S:8): not a seat"
  seats "''${good[@]}" PI_SESSION_MODEL=fakecloud/acme/zeta-9000:high
  modes 1 1
  both_have "pi-seats: PI_SESSION_MODEL: set on lines 3 and 8 of $S. Keep one."

  # Values: provider/id[:level].
  for bad in acme-zeta-9000 /acme/zeta-9000 fakecloud/ fakecloud/:high; do
    both 1 0 "PI_SPAWN_MODEL=$bad"
    both_have 'pi-seats: PI_SPAWN_MODEL: not provider/id[:level]'
  done
  both 0 0 'PI_SPAWN_MODEL=fakecloud/acme/sigma-3:beta'
  both 0 0 'PI_SPAWN_MODEL=fakecloud/acme/sigma-3:beta:off'

  # Trust.
  both 1 0 'PI_SPAWN_MODEL=othercloud/acme/omega-2'
  both_have 'pi-seats: PI_SPAWN_MODEL: its provider is not one of fakecloud'

  # The catalog: an error at deploy, a warning at start that skips the
  # rules needing the catalog entry.
  seats "''${good[@]}" PI_SPAWN_MODEL=fakecloud/acme/nope-1:high
  run 1 pi-seats check --deploy
  has 'pi-seats: PI_SPAWN_MODEL: its id is not listed under its provider in models.json'
  run 0 pi-seats check --start
  has 'pi-seats: warning: PI_SPAWN_MODEL: not in the catalog'
  seats "''${good[@]}" PI_SPAWN_MODEL=fakecloud/acme/zeta-9000:ultra
  run 1 pi-seats check --deploy
  has 'pi-seats: PI_SPAWN_MODEL: its id is not listed under its provider in models.json'
  run 0 env PI_AGENT_MODEL_VISION=fakecloud/acme/nope-1 pi-seats check --start
  has 'pi-seats: warning: PI_AGENT_MODEL_VISION: not in the catalog'
  run 0 env PI_SESSION_MODEL=fakecloud/acme/nope-1:max pi-seats check --start
  has 'pi-seats: warning: PI_SESSION_MODEL: not in the catalog'

  # Levels pi clamps to another one.
  both 1 0 'PI_SPAWN_MODEL=fakecloud/acme/zeta-9000:max'
  both_have "pi-seats: PI_SPAWN_MODEL: pi runs level max as xhigh: the entry's thinkingLevelMap maps max to null."
  both 1 0 'PI_SPAWN_MODEL=fakecloud/acme/omega-2:xhigh'
  both_have "pi-seats: PI_SPAWN_MODEL: pi runs level xhigh as high: pi runs xhigh only when the entry's thinkingLevelMap names it."
  both_have "thinkingLevelMap a \"xhigh\" value the endpoint takes in pi_models_json, or use :high, in"
  both 0 0 'PI_SPAWN_MODEL=fakecloud/acme/zeta-9000:high'
  both 0 0 'PI_SPAWN_MODEL=fakecloud/acme/zeta-9000:minimal'
  both 0 0 'PI_SPAWN_MODEL=fakecloud/acme/zeta-9000'
  both 1 0 'PI_SPAWN_MODEL=fakecloud/acme/kappa-7:low'
  both_have 'pi-seats: PI_SPAWN_MODEL: pi runs level low as off: its catalog entry does not say "reasoning": true.'
  both 1 0 'PI_SPAWN_MODEL=fakecloud/acme/sigma-3:beta:high'
  both_have 'pi-seats: PI_SPAWN_MODEL: pi runs level high as off: its catalog entry does not say "reasoning": true.'
  both 0 0 'PI_SPAWN_MODEL=fakecloud/acme/kappa-7:off'
  both 0 0 'PI_SPAWN_MODEL=fakecloud/acme/kappa-7'

  # Required: the session, each `seat: required` agent, each --require.
  seats "''${good[@]:3}"
  run 1 pi-seats check --deploy
  has 'pi-seats: PI_SESSION_MODEL: required, and not set'
  run 1 pi-seats check --start
  has 'pi-seats: PI_SESSION_MODEL: required, and not set'
  run 0 env PI_SESSION_MODEL=fakecloud/acme/zeta-9000 pi-seats check --start
  printf '%s\n' "''${good[@]}" | grep -v PI_AGENT_MODEL_VISION >"$S"
  run 1 pi-seats check --deploy
  has 'pi-seats: PI_AGENT_MODEL_VISION: required, and not set'
  # An agent's seat doesn't stop the session; the agent refuses when used.
  run 0 pi-seats check --start
  has 'pi-seats: warning: PI_AGENT_MODEL_VISION: required, and not set'
  has 'warning(s), which fail the next deploy check'
  run 0 env PI_AGENT_MODEL_VISION=fakecloud/acme/omega-2 pi-seats check --start
  printf '%s\n' "''${good[@]}" | grep -v PI_ADVISOR_MODEL >"$S"
  run 0 pi-seats check --deploy
  run 0 pi-seats check --start
  run 1 pi-seats check --start --require PI_ADVISOR_MODEL --require PI_SPAWN_MODEL
  has 'pi-seats: PI_ADVISOR_MODEL: required, and not set'
  has 'pi-seats: PI_SPAWN_MODEL: required, and not set'
  run 0 env PI_ADVISOR_MODEL=fakecloud/acme/omega-2 pi-seats check --start --require PI_ADVISOR_MODEL
  run 2 pi-seats check --start --require
  run 2 pi-seats check --start --require FOO
  run 2 pi-seats check --start --needs PI_ADVISOR_MODEL
  run 2 pi-seats check --deploy --require PI_ADVISOR_MODEL
  run 2 pi-seats check

  # The advisor and the critic aren't the session's model, whatever the level.
  both 1 0 'PI_ADVISOR_MODEL=fakecloud/acme/zeta-9000:low'
  both_have 'pi-seats: PI_ADVISOR_MODEL: same model as PI_SESSION_MODEL'
  run 1 pi-seats check --start --require PI_ADVISOR_MODEL
  has 'pi-seats: PI_ADVISOR_MODEL: same model as PI_SESSION_MODEL'
  both 1 0 'PI_AGENT_MODEL_CRITIC=fakecloud/acme/zeta-9000'
  both_have 'pi-seats: PI_AGENT_MODEL_CRITIC: same model as PI_SESSION_MODEL'

  # An agent with `needs: image` gets a model that takes images.
  both 1 0 'PI_AGENT_MODEL_VISION=fakecloud/acme/kappa-7'
  both_have "pi-seats: PI_AGENT_MODEL_VISION: the model's catalog entry has no \"image\" in input"

  # Agents: a name no variable can hold, and a file task.ts skips.
  agent bad-name bad-name
  both 1 0
  both_have 'pi-seats: agents/bad-name.md: name is not [A-Za-z0-9_]+, so no variable can hold its seat'
  rm "$A/agents/bad-name.md"
  printf -- '---\nname: nodesc\nseat: required\n---\n' >"$A/agents/nodesc.md"
  both 1 0 'PI_AGENT_MODEL_NODESC=fakecloud/acme/omega-2'
  both_have "pi-seats: PI_AGENT_MODEL_NODESC ($S:8): not a seat"
  rm "$A/agents/nodesc.md"

  # start checks the caller's env over the file; empty counts as unset.
  # deploy reads only the file.
  seats "''${good[@]}"
  run 1 env PI_SESSION_MODEL=othercloud/acme/omega-2 pi-seats check --start
  has 'pi-seats: PI_SESSION_MODEL: its provider is not one of fakecloud'
  run 0 env PI_SESSION_MODEL=othercloud/acme/omega-2 pi-seats check --deploy
  run 0 env PI_SESSION_MODEL= pi-seats check --start
  quiet
  run 0 env PI_AGENT_MODEL_NOAGENT=x pi-seats check --start

  # get: env, else file, else nothing.
  seats "''${good[@]}" PI_SPAWN_MODEL=fakecloud/acme/omega-2:low
  [ "$(pi-seats get PI_SPAWN_MODEL)" = fakecloud/acme/omega-2:low ] || fail "get: file"
  [ "$(PI_SPAWN_MODEL=fakecloud/acme/zeta-9000 pi-seats get PI_SPAWN_MODEL)" = fakecloud/acme/zeta-9000 ] || fail "get: env"
  [ "$(PI_SPAWN_MODEL= pi-seats get PI_SPAWN_MODEL)" = fakecloud/acme/omega-2:low ] || fail "get: empty env"
  run 0 pi-seats get PI_DELEGATE_MODEL
  quiet
  run 0 pi-seats get PI_AGENT_MODEL_ANYONE
  quiet
  run 2 pi-seats get PI_SESSION
  run 2 pi-seats get
  [ "$(PI_CLASSIFY_MODEL=fakecloud/acme/zeta-9000 pi-seats list)" = "$(printf '%s\t%s\n' \
    PI_SESSION_MODEL fakecloud/acme/zeta-9000:xhigh \
    PI_ADVISOR_MODEL fakecloud/acme/omega-2:high \
    PI_AGENT_MODEL_CRITIC fakecloud/acme/omega-2:high \
    PI_AGENT_MODEL_VISION fakecloud/acme/omega-2 \
    PI_CLASSIFY_MODEL fakecloud/acme/kappa-7:off \
    PI_SPAWN_MODEL fakecloud/acme/omega-2:low)" ] || fail "list: $(pi-seats list)"

  # No seats file: no seats, nothing listed, env still counts.
  rm "$S"
  run 1 pi-seats check --start
  has 'pi-seats: PI_SESSION_MODEL: required, and not set'
  has 'pi-seats: warning: PI_AGENT_MODEL_CRITIC: required, and not set'
  run 0 env PI_SESSION_MODEL=fakecloud/acme/zeta-9000 PI_AGENT_MODEL_CRITIC=fakecloud/acme/omega-2 \
    PI_AGENT_MODEL_VISION=fakecloud/acme/omega-2 pi-seats check --start
  run 0 pi-seats list
  quiet
  run 0 pi-seats get PI_SESSION_MODEL
  quiet

  # A seats file that can't be read is an error, not "no seats".
  mkdir "$S"
  run 1 pi-seats check --deploy
  has "pi-seats: $S: cannot read it (IsADirectoryError)"
  run 1 env PI_SESSION_MODEL=fakecloud/acme/zeta-9000 pi-seats check --start
  run 1 pi-seats list
  run 1 pi-seats get PI_SPAWN_MODEL
  [ "$(PI_SPAWN_MODEL=fakecloud/acme/zeta-9000 pi-seats get PI_SPAWN_MODEL)" = fakecloud/acme/zeta-9000 ] || fail "get: env over an unreadable file"
  rmdir "$S"

  # The catalog: missing or unreadable fails both, saying where it should be.
  seats "''${good[@]}"
  mv "$A/models.json" "$T/models.json"
  run 1 pi-seats check --deploy
  has "pi-seats: $A/models.json does not exist"
  run 1 pi-seats check --start
  has "pi-seats: $A/models.json does not exist"
  has "edited with this host's sops file"
  ln -s "$T/nowhere.json" "$A/models.json"
  run 1 pi-seats check --start
  has "pi-seats: $A/models.json links to $T/nowhere.json, which does not exist"
  rm "$A/models.json"
  echo '{' >"$A/models.json"
  run 1 pi-seats check --start
  has "pi-seats: $A/models.json: cannot read it as JSON (JSONDecodeError)"
  mv "$T/models.json" "$A/models.json"

  # The package's defaults: no seats file and no trust list.
  run 0 env PI_SESSION_MODEL=othercloud/acme/omega-2 PI_AGENT_MODEL_CRITIC=fakecloud/acme/omega-2 \
    PI_AGENT_MODEL_VISION=fakecloud/acme/omega-2 ${pkgs.pi-seats}/bin/pi-seats check --start
  quiet
  run 0 ${pkgs.pi-seats}/bin/pi-seats list
  quiet
  run 0 ${pkgs.pi-seats}/bin/pi-seats source
  quiet
  [ "$(${
    pkgs.pi-seats.override { secretsSource = "nix/secrets/host.yaml"; }
  }/bin/pi-seats source)" = nix/secrets/host.yaml ] \
    || fail "source: does not print the configured file"

  touch "$out"
''
