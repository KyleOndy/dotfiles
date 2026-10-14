# Flake check for mcloud-pins (nix/pkgs/mcloud-pins) against a stub
# endpoint: the listing and one-token probes, the image, reasoning, tool and
# context checks and the requests they send (the token field and the
# reasoning_effort the engine would send per entry and level), every early failure,
# a fix line under every failure and warning, and that --deploy output names
# no fixture id.
#
# The fixtures use made-up ids. The stub endpoint takes its behaviour from
# ~/endpoint.json: `served` ids, the listing's HTTP status, per id a mode or
# an HTTP status for each kind of request (`text` for the one-token probe,
# `image`, `reason`, `tools`, `context`), and `contextLimit`, the prompt in
# tokens above which a context request is refused.
{ pkgs }:
let
  baseUrl = "http://mcloud.invalid/v1";
  models = [
    {
      id = "acme/zeta-9000";
      input = [ "text" ];
      reasoning = true;
      thinkingLevelMap = {
        xhigh = "high";
        max = null;
        off = "none";
      };
      contextWindow = 2000;
      maxTokens = 200;
    }
    {
      id = "acme/omega-2";
      input = [
        "text"
        "image"
      ];
      reasoning = false;
      compat.maxTokensField = "max_tokens";
      contextWindow = 1000;
      maxTokens = 100;
    }
    {
      id = "acme/kappa-7";
      input = [
        "text"
        "image"
      ];
      reasoning = true;
    }
  ];
  catalog =
    mcloud:
    pkgs.writeText "models.json" (
      builtins.toJSON {
        providers = {
          inherit mcloud;
          othercloud.models = [
            {
              id = "acme/sigma-3";
              input = [
                "text"
                "image"
              ];
            }
          ];
        };
      }
    );
  good = catalog { inherit baseUrl models; };
  fields = catalog {
    inherit baseUrl;
    models = models ++ [
      {
        id = "acme/lambda-4";
        input = [ "text" ];
        reasoning = true;
        compat.supportsReasoningEffort = false;
      }
    ];
  };
  providerCompat = catalog {
    inherit baseUrl;
    compat.maxTokensField = "max_tokens";
    models = map (m: removeAttrs m [ "compat" ]) models ++ [
      {
        id = "acme/lambda-4";
        input = [ "text" ];
        compat.maxTokensField = "max_completion_tokens";
      }
    ];
  };
  formatted = catalog {
    inherit baseUrl models;
    compat.thinkingFormat = "qwen";
  };
  noBaseUrl = catalog { inherit models; };
  noModels = catalog {
    inherit baseUrl;
    models = [ ];
  };
  # The shape sops-nix leaves when the secret is missing: a store link on to
  # a file that is not there.
  dangling = pkgs.runCommand "models.json" { } "ln -s /run/secrets/nope $out";

  curl = pkgs.writeShellScriptBin "curl" ''
    set -euo pipefail
    jq=${pkgs.jq}/bin/jq
    E=$HOME/endpoint.json
    auth="" data="" url=""
    fail() { echo "curl stub: $*" >&2; exit 99; }
    while [ $# -gt 0 ]; do
      case $1 in
      -s) shift ;;
      --max-time | -w) shift 2 ;;
      -H)
        case $2 in
        Authorization:*) fail "the key is in curl's argv" ;;
        @*) auth=$(cat "''${2#@}") ;;
        esac
        shift 2
        ;;
      --data-binary)
        [ "$2" = @- ] || fail "the body is in curl's argv"
        data=$(cat)
        shift 2
        ;;
      *)
        url=$1
        shift
        ;;
      esac
    done
    answer() { # <code> [body], as `-w '\n%{http_code}'` prints them
      printf '%s\n%s' "''${2:-}" "$1"
      [ "$1" != 000 ] || exit 28
      exit 0
    }
    out() { # <message fields> <finish_reason> [usage]
      answer 200 "$($jq -nc --argjson msg "$1" --arg f "$2" --argjson u "''${3:-null}" \
        '{choices: [{message: ({role: "assistant"} + $msg), finish_reason: $f}]} + (if $u then {usage: $u} else {} end)')"
    }
    say() { # <content> [finish_reason] [usage]
      out "$($jq -nc --arg c "$1" '{content: $c}')" "''${2:-stop}" "''${3:-null}"
    }
    thought() { # <reasoning tokens> [content] [finish_reason]
      say "''${2-17}" "''${3:-stop}" "{\"completion_tokens_details\": {\"reasoning_tokens\": $1}}"
    }
    call() { # <name> <arguments>
      out "$($jq -nc --arg n "$1" --arg a "$2" \
        '{content: null, tool_calls: [{id: "call_1", type: "function", function: {name: $n, arguments: $a}}]}')" tool_calls
    }
    [ "$auth" = "Authorization: Bearer test-key" ] || answer 401 '{"error": {"message": "bad key"}}'
    case $url in
    ${baseUrl}/models)
      answer "$($jq -r '.listing // 200' "$E")" "$($jq -c '{data: [.served[] | {id: ., object: "model"}]}' "$E")"
      ;;
    ${baseUrl}/chat/completions) ;;
    *) answer 404 '{}' ;;
    esac

    printf '%s\n' "$data" >>"$HOME/requests"
    model=$($jq -r .model <<<"$data")
    effort=$($jq -r '.reasoning_effort // ""' <<<"$data")
    kind=$($jq -r 'if .tools then "tools"
      elif (.messages[0].content | type) == "array" then "image"
      elif .messages[0].content == "hi" then "text"
      elif (.messages[0].content | startswith("Remember this marker")) then "context"
      else "reason" end' <<<"$data")
    mode=$($jq -r --arg m "$model" --arg k "$kind" '.[$k][$m] // "ok"' "$E")
    limit=$($jq -r --arg m "$model" '.contextLimit[$m] // empty' "$E")
    if [ "$kind" = context ] && [ -n "$limit" ] &&
      [ $(($($jq -r '.messages[0].content | length' <<<"$data") / 4)) -gt "$limit" ]; then
      answer 400 "$($jq -nc --arg l "$limit" '{error: {message: ("maximum context length is " + $l + " tokens")}}')"
    fi
    case $kind:$mode in
    *:[0-9][0-9][0-9])
      answer "$mode" "$($jq -nc --arg m "$model" '{error: {message: ($m + " cannot take this request")}}')"
      ;;
    text:ok) say h length ;;
    text:flaky*) # refuses every odd-numbered probe of this id
      if [ "$($jq -s --arg m "$model" 'map(select(.model == $m and .messages[0].content == "hi")) | length % 2' "$HOME/requests")" = 1 ]; then
        answer "''${mode#flaky}" '{"error": {"message": "refused"}}'
      fi
      say h length
      ;;
    image:ok) say Green. ;;
    image:greenish) say greenish ;;
    image:red) say $'The image is\nred.' ;;
    image:empty) say "" length ;;
    reason:ok)
      if [ -n "$effort" ] && [ "$effort" != none ]; then thought 64; else thought 0; fi
      ;;
    reason:always) thought 64 ;;
    reason:never) thought 0 ;;
    reason:silent) say 17 ;;
    reason:text)
      if [ -n "$effort" ]; then
        out '{"content": "17", "reasoning_content": "12 for pens, 21 for notebooks, 50 - 33 = 17."}' stop
      else
        say 17
      fi
      ;;
    reason:empty) thought 4096 "" length ;;
    reason:cut) thought 4096 "Four pens cost" length ;;
    reason:wrong) thought 64 18 ;;
    tools:ok) call get_weather '{"city": "Paris"}' ;;
    tools:prose) say "It is sunny in Paris." ;;
    tools:name) call get_time '{"city": "Paris"}' ;;
    tools:garbled) call get_weather '{city: Paris' ;;
    tools:elsewhere) call get_weather '{"city": "London"}' ;;
    context:ok) say "$($jq -r '.messages[0].content | capture("^Remember this marker: (?<m>[a-z0-9-]+)").m' <<<"$data")" ;;
    context:drop) say "There is no marker." ;;
    *) fail "no mode $kind:$mode" ;;
    esac
  '';

  alamodeSeats = pkgs.writeShellScript "alamode-seats" ''
    case "$*" in
    list) cat "$HOME/seats" ;;
    source) cat "$HOME/source" 2>/dev/null || true ;;
    *) exit 2 ;;
    esac
  '';

  # The probe's retry pause is wall time the stub endpoint has no use for.
  # symlinkJoin keeps the first path's file on a conflict.
  coreutils = pkgs.symlinkJoin {
    name = "coreutils-nosleep";
    paths = [
      (pkgs.writeShellScriptBin "sleep" ":")
      pkgs.coreutils
    ];
  };

  mcloud-pins = pkgs.mcloud-pins.override { inherit curl coreutils; };
  baked = pkgs.mcloud-pins.override {
    inherit curl coreutils;
    keyCommand = "echo test-key";
  };
in
pkgs.runCommand "mcloud-pins-check"
  {
    nativeBuildInputs = [
      mcloud-pins
      pkgs.jq
    ];
  }
  ''
    set -euo pipefail
    fail() {
      echo "FAIL: $*" >&2
      cat "$T/out" >&2 2>/dev/null || true
      exit 1
    }
    run() { # <exit> [arg]...: mcloud-pins into $T/out; every failure and warning has a fix line under it
      want=$1
      shift
      rc=0
      mcloud-pins "$@" >"$T/out" 2>&1 || rc=$?
      [ "$rc" = "$want" ] || fail "mcloud-pins $*: exit $rc, wanted $want"
      awk 'want && !/^  fix: / { exit 1 }
        { want = /^mcloud-pins: / && !/, each with its fix above$/ && !/ served and answering, / } END { exit want }' "$T/out" ||
        fail "mcloud-pins $*: a failure without a fix line"
      if grep -qiE 'acme|zeta|omega|kappa|lambda|sigma|tau|nope' "$LOG" 2>/dev/null; then fail "mcloud-pins $*: the request log names a fixture id"; fi
    }
    both() { # <exit>: --deploy into $T/deploy, which names no fixture id, and plain into $T/plain
      run "$1" --deploy
      if grep -qiE 'acme|zeta|omega|kappa|lambda|sigma|tau|nope' "$T/out"; then fail "--deploy printed a fixture id"; fi
      cp "$T/out" "$T/deploy"
      run "$1"
      cp "$T/out" "$T/plain"
    }
    dep() {
      grep -qxF -- "$1" "$T/deploy" || fail "--deploy: no line: $1"
    }
    plain() {
      grep -qxF -- "$1" "$T/plain" || fail "plain: no line: $1"
    }
    row() { # <columns, single-spaced>
      tr -s ' ' <"$T/plain" | grep -qxF -- "$1" || fail "plain: no row: $1"
    }
    endpoint() { # [jq object over the default]
      jq -n '{served: ["acme/zeta-9000", "acme/omega-2", "acme/kappa-7", "acme/lambda-4", "acme/tau-5"]}'" + ''${1:-null}" \
        >"$HOME/endpoint.json"
      rm -f "$HOME/requests" "$LOG"
    }
    # A check with no answer, a 429 or a 5xx says nothing about the pin: a
    # problem by hand, only a warning under --deploy.
    unanswered() { # <endpoint> <subject: what> <fix by hand>
      endpoint "$1"
      run 0 --deploy
      if grep -qiE 'acme|zeta|omega|kappa|lambda|sigma|tau|nope' "$T/out"; then fail "--deploy printed a fixture id"; fi
      cp "$T/out" "$T/deploy"
      dep "mcloud-pins: warning: $2, so it was not checked"
      dep "  fix: rerun mcloud-pins once the endpoint answers"
      run 1
      cp "$T/out" "$T/plain"
      plain "  fix: rerun mcloud-pins; if it fails the same way, $3"
    }
    catalog() {
      ln -sfn "$1" "$A/models.json"
    }
    requests() { # <jq test over every request this endpoint saw>
      jq -se --arg image "What color fills this image? Reply with one lowercase word." \
        --arg sum "A shop sells pens at 3 dollars each and notebooks at 7 dollars each. Ana buys 4 pens and 3 notebooks and pays with a 50 dollar bill. How many dollars of change does she get? Reply with the number only." \
        --arg tool "What is the weather in Paris? Use the tool." '
        def kind: if .tools then "tools" elif (.messages[0].content | type) == "array" then "image"
          elif .messages[0].content == "hi" then "text" elif .messages[0].content == $sum then "reason"
          elif (.messages[0].content | startswith("Remember this marker: quartz-pelican-4417\n\n")) then "context"
          else "other" end;
        def budget: .max_tokens // .max_completion_tokens;
        def of($k): map(select(kind == $k));
        '"$1" "$HOME/requests" >/dev/null || fail "requests: $1"
    }

    T=$TMPDIR/mp
    export HOME=$T/home
    LOG=$HOME/.local/state/mcloud-pins/requests.log
    A=$HOME/.pi/agent
    mkdir -p "$A" "$T/bin"
    ln -s ${alamodeSeats} "$T/bin/alamode-seats"
    export PATH=$T/bin:$PATH
    export MCLOUD_API_KEY=test-key
    unset MCLOUD_API_KEY_COMMAND
    printf '%s\n' nix/secrets/fake.yaml >"$HOME/source"
    printf '%s\t%s\n' \
      ALAMODE_SESSION_MODEL mcloud/acme/zeta-9000:xhigh \
      ALAMODE_ADVISOR_MODEL mcloud/acme/zeta-9000:low \
      ALAMODE_AGENT_MODEL_VISION mcloud/acme/omega-2 \
      ALAMODE_AGENT_MODEL_CRITIC mcloud/acme/kappa-7:high \
      ALAMODE_CLASSIFY_MODEL mcloud/acme/kappa-7:off \
      ALAMODE_SPAWN_MODEL othercloud/acme/sigma-3 >"$HOME/seats"
    cp "$HOME/seats" "$T/seats.good"
    catalog ${good}
    S='in nix/secrets/fake.yaml'
    Z0='alamode_models_json providers.mcloud.models[0]'
    O0='alamode_models_json providers.mcloud.models[1]'
    K0='alamode_models_json providers.mcloud.models[2]'
    Z="ALAMODE_SESSION_MODEL, ALAMODE_ADVISOR_MODEL, $Z0"
    O="ALAMODE_AGENT_MODEL_VISION, $O0"
    K="ALAMODE_AGENT_MODEL_CRITIC, ALAMODE_CLASSIFY_MODEL, $K0"
    SEE="remove \"image\" from input in $O0, or point ALAMODE_AGENT_MODEL_VISION at a model that sees images, $S"
    SEE_K="remove \"image\" from input in $K0, or point ALAMODE_AGENT_MODEL_CRITIC, ALAMODE_CLASSIFY_MODEL at a model that sees images, $S"
    PASS='mcloud-pins: 3 pins served and answering, 2 image checks, 4 reasoning checks and 3 tool checks passed'

    # All pass: one line at deploy, the table otherwise.
    endpoint
    both 0
    [ "$(cat "$T/deploy")" = "$PASS" ] || fail "deploy success line"
    row "acme/kappa-7 yes 200 ok ok ok $K"
    row "acme/omega-2 yes 200 ok - ok $O"
    row "acme/zeta-9000 yes 200 - ok ok $Z"
    plain 'served, unpinned: acme/lambda-4 acme/tau-5'
    plain "$PASS"

    # What went out, over both runs. pi's token field: max_tokens for the
    # entry whose compat says so, max_completion_tokens otherwise. Its
    # reasoning_effort: a mapped level's mapping, else the level's name, and
    # at off with no off mapping nothing; only the reasoning check sends
    # one. The image goes to image entries only, tools to the ids behind a
    # tool seat, and othercloud's model is not mcloud's to check. No context
    # check without --context.
    requests '
      all(.[]; if .model == "acme/omega-2" then has("max_tokens") and (has("max_completion_tokens") | not)
        else has("max_completion_tokens") and (has("max_tokens") | not) end)
      and of("other") == [] and of("context") == []
      and (of("text") | length == 6 and all(budget == 1 and (keys | length) == 3))
      and (of("image") | length == 4 and (map(.model) | unique) == ["acme/kappa-7", "acme/omega-2"]
        and all(budget == 1024 and (keys | length) == 3
          and .messages == [{role: "user", content: [{type: "text", text: $image},
            {type: "image_url", image_url: {url: .messages[0].content[1].image_url.url}}]}]
          and (.messages[0].content[1].image_url.url | startswith("data:image/png;base64,"))))
      and (of("reason") | length == 8 and all(budget == 4096)
        and (map([.model, .reasoning_effort]) | unique)
          == [["acme/kappa-7", null], ["acme/kappa-7", "high"], ["acme/zeta-9000", "high"], ["acme/zeta-9000", "low"]])
      and (of("tools") | length == 6
        and (map(.model) | unique) == ["acme/kappa-7", "acme/omega-2", "acme/zeta-9000"]
        and all(budget == 4096 and .tool_choice == "auto" and .messages == [{role: "user", content: $tool}]
          and .tools == [{type: "function", function: {name: "get_weather", description: "Current weather for a city.",
            parameters: {type: "object", properties: {city: {type: "string"}}, required: ["city"]}}}]))
      and (map(select(kind != "reason")) | all(has("reasoning_effort") | not))'
    printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0@\0\0\0@' >"$T/head"
    jq -r 'select(.messages[0].content | type == "array") | .messages[0].content[1].image_url.url' "$HOME/requests" |
      sed -n 's/^data:image\/png;base64,//; 1p' | base64 -d | cmp -n 24 - "$T/head" ||
      fail "the image is not a 64x64 PNG"

    # pi's fields per entry and level: zeta maps xhigh and off, maps max to
    # null so max clamps to xhigh; kappa maps nothing, so xhigh clamps to
    # high and off sends nothing; omega does not reason, so high runs at off
    # and takes max_tokens; lambda turns reasoning_effort off in compat, so
    # its level is ignored.
    catalog ${fields}
    printf '%s\t%s\n' \
      ALAMODE_DELEGATE_MODEL mcloud/acme/zeta-9000:off \
      ALAMODE_AGENT_MODEL_PLANNER mcloud/acme/zeta-9000:max \
      ALAMODE_AGENT_MODEL_SCOUT mcloud/acme/omega-2:high \
      ALAMODE_AGENT_MODEL_SCRIBE mcloud/acme/kappa-7:xhigh \
      ALAMODE_AGENT_MODEL_NOEFFORT mcloud/acme/lambda-4:high >>"$HOME/seats"
    endpoint
    both 1
    requests '
      (of("reason") | map([.model, .reasoning_effort, budget]) | unique)
        == [["acme/kappa-7", null, 4096], ["acme/kappa-7", "high", 4096], ["acme/lambda-4", null, 4096],
          ["acme/omega-2", null, 4096], ["acme/zeta-9000", "high", 4096], ["acme/zeta-9000", "low", 4096],
          ["acme/zeta-9000", "none", 4096]]
      and (of("reason") | length == 18)
      and (of("tools") | map(.model) | unique == ["acme/kappa-7", "acme/lambda-4", "acme/omega-2", "acme/zeta-9000"])'
    dep 'mcloud-pins: ALAMODE_AGENT_MODEL_NOEFFORT, alamode_models_json providers.mcloud.models[3]: accepted level high and did no reasoning, so the level is ignored (0 reasoning tokens with no reasoning_effort)'
    dep "  fix: correct thinkingLevelMap, reasoning or compat.supportsReasoningEffort in alamode_models_json providers.mcloud.models[3] to what this model honours, or drop the level from ALAMODE_AGENT_MODEL_NOEFFORT, $S"
    dep 'mcloud-pins: 1 problem across 4 pins, each with its fix above'
    endpoint '{reason: {"acme/zeta-9000": "never", "acme/omega-2": "always"}}'
    both 1
    dep "mcloud-pins: ALAMODE_AGENT_MODEL_PLANNER, $Z0: accepted level max (the engine clamps it to xhigh) and did no reasoning, so the level is ignored (0 reasoning tokens with reasoning_effort high)"
    dep "mcloud-pins: ALAMODE_AGENT_MODEL_SCOUT, $O0: reasons at level high (the engine clamps it to off): the seat still spends its budget thinking (64 reasoning tokens with no reasoning_effort)"
    dep "  fix: set \"reasoning\": true and a thinkingLevelMap.off that turns reasoning off in $O0 (the engine sends it at off), or point ALAMODE_AGENT_MODEL_SCOUT at a model that answers without reasoning, $S"
    row "acme/zeta-9000 yes 200 - FAIL ok ALAMODE_SESSION_MODEL, ALAMODE_ADVISOR_MODEL, ALAMODE_DELEGATE_MODEL, ALAMODE_AGENT_MODEL_PLANNER, $Z0"
    if grep -q '^mcloud-pins: ALAMODE_DELEGATE_MODEL,' "$T/deploy"; then fail "zeta at off failed on no reasoning"; fi
    cp "$T/seats.good" "$HOME/seats"

    # the engine merges the provider's compat into each entry, the entry's winning.
    catalog ${providerCompat}
    endpoint
    both 0
    requests '
      length > 0 and all(.[]; if .model == "acme/lambda-4" then has("max_completion_tokens") and (has("max_tokens") | not)
        else has("max_tokens") and (has("max_completion_tokens") | not) end)
      and (map(.model) | index("acme/lambda-4") != null)'

    # A thinkingFormat changes what the engine sends for reasoning, so the check
    # stands aside for entries that reason.
    catalog ${formatted}
    endpoint
    both 0
    requests 'all(of("reason")[]; .model == "acme/omega-2") and (of("tools") | length > 0)'
    grep -q '^mcloud-pins: warning: .*: the reasoning check at level [a-z]* was skipped: compat.thinkingFormat is set,' "$T/deploy" ||
      fail "thinkingFormat: no skip warning"
    catalog ${good}

    # Reasoning: off that reasons, a level that does not, a level the
    # endpoint gives no sign of, reasoning text as the sign, an empty, a
    # cut-off and a wrong answer, and refusals.
    endpoint '{reason: {"acme/kappa-7": "always"}}'
    both 1
    dep "mcloud-pins: ALAMODE_CLASSIFY_MODEL, $K0: reasons at off: a seat at :off still spends its budget thinking (64 reasoning tokens with no reasoning_effort)"
    dep "  fix: set \"reasoning\": true and a thinkingLevelMap.off that turns reasoning off in $K0 (the engine sends it at off), or point ALAMODE_CLASSIFY_MODEL at a model that answers without reasoning, $S"
    dep 'mcloud-pins: 1 problem across 3 pins, each with its fix above'
    row "acme/kappa-7 yes 200 ok FAIL ok $K"
    endpoint '{reason: {"acme/zeta-9000": "never"}}'
    both 1
    dep "mcloud-pins: ALAMODE_SESSION_MODEL, $Z0: accepted level xhigh and did no reasoning, so the level is ignored (0 reasoning tokens with reasoning_effort high)"
    dep "  fix: correct thinkingLevelMap, reasoning or compat.supportsReasoningEffort in $Z0 to what this model honours, or drop the level from ALAMODE_SESSION_MODEL, $S"
    dep "mcloud-pins: ALAMODE_ADVISOR_MODEL, $Z0: accepted level low and did no reasoning, so the level is ignored (0 reasoning tokens with reasoning_effort low)"
    plain "mcloud-pins: acme/zeta-9000 (ALAMODE_ADVISOR_MODEL, $Z0): accepted level low and did no reasoning, so the level is ignored (0 reasoning tokens with reasoning_effort low)"
    endpoint '{reason: {"acme/zeta-9000": "silent"}}'
    both 0
    dep "mcloud-pins: warning: ALAMODE_SESSION_MODEL, $Z0: cannot tell whether level xhigh reasons; the endpoint reports no reasoning tokens (reasoning_effort high)"
    dep "  fix: confirm by hand that this model reasons with reasoning_effort high; if it does not, drop the level from ALAMODE_SESSION_MODEL, $S"
    dep 'mcloud-pins: 3 pins served and answering, 2 image checks, 2 reasoning checks and 3 tool checks passed, 2 warnings above'
    row "acme/zeta-9000 yes 200 - warn ok $Z"
    endpoint '{reason: {"acme/zeta-9000": "text"}}'
    both 0
    dep "$PASS"
    endpoint '{reason: {"acme/kappa-7": "empty"}}'
    both 1
    dep "mcloud-pins: ALAMODE_AGENT_MODEL_CRITIC, $K0: the reasoning check at level high answered with no text (finish_reason length)"
    dep "  fix: a three-step sum should not need 4096 tokens: lower the level in ALAMODE_AGENT_MODEL_CRITIC, or point it at another model, $S"
    endpoint '{reason: {"acme/zeta-9000": "cut"}}'
    both 1
    dep "mcloud-pins: ALAMODE_SESSION_MODEL, $Z0: the reasoning check at level xhigh was cut off at the 4096-token budget (finish_reason length)"
    endpoint '{reason: {"acme/zeta-9000": "wrong"}}'
    both 0
    dep "mcloud-pins: warning: ALAMODE_SESSION_MODEL, $Z0: the reasoning check at level xhigh answered, but not 17"
    dep '  fix: rerun mcloud-pins; a model that keeps missing a three-step sum is a poor fit for ALAMODE_SESSION_MODEL'
    plain "mcloud-pins: warning: acme/zeta-9000 (ALAMODE_SESSION_MODEL, $Z0): the reasoning check at level xhigh answered, but not 17 (it said: 18)"
    endpoint '{reason: {"acme/zeta-9000": 400}}'
    both 1
    dep "mcloud-pins: ALAMODE_SESSION_MODEL, $Z0: the reasoning check at level xhigh answers HTTP 400 to reasoning_effort high"
    dep "  fix: correct thinkingLevelMap, reasoning or compat.supportsReasoningEffort in $Z0 so the engine sends what the endpoint takes, or pick another level for ALAMODE_SESSION_MODEL, $S"
    plain "mcloud-pins: acme/zeta-9000 (ALAMODE_SESSION_MODEL, $Z0): the reasoning check at level xhigh answers HTTP 400 (the endpoint said: acme/zeta-9000 cannot take this request) to reasoning_effort high"
    unanswered '{reason: {"acme/kappa-7": 503}}' "ALAMODE_CLASSIFY_MODEL, $K0: the reasoning check at level off answers HTTP 503" \
      "correct thinkingLevelMap, reasoning or compat.supportsReasoningEffort in $K0 so the engine sends what the endpoint takes, or pick another level for ALAMODE_CLASSIFY_MODEL, $S"
    unanswered '{reason: {"acme/kappa-7": 429}}' "ALAMODE_CLASSIFY_MODEL, $K0: the reasoning check at level off answers HTTP 429" \
      "correct thinkingLevelMap, reasoning or compat.supportsReasoningEffort in $K0 so the engine sends what the endpoint takes, or pick another level for ALAMODE_CLASSIFY_MODEL, $S"

    # Tools: prose, another tool, garbled or wrong arguments, refusals.
    endpoint '{tools: {"acme/zeta-9000": "prose"}}'
    both 1
    dep "mcloud-pins: ALAMODE_SESSION_MODEL, $Z0: the tool check got prose, not a tool call, so the model does not call tools here"
    dep "  fix: point ALAMODE_SESSION_MODEL at a model that calls tools, $S"
    plain "mcloud-pins: acme/zeta-9000 (ALAMODE_SESSION_MODEL, $Z0): the tool check got prose, not a tool call (it said: It is sunny in Paris.), so the model does not call tools here"
    row "acme/zeta-9000 yes 200 - ok FAIL $Z"
    endpoint '{tools: {"acme/kappa-7": "name"}}'
    both 1
    dep "mcloud-pins: ALAMODE_AGENT_MODEL_CRITIC, $K0: the tool check called another tool, not get_weather"
    dep "  fix: point ALAMODE_AGENT_MODEL_CRITIC at a model that calls tools, $S"
    plain "mcloud-pins: acme/kappa-7 (ALAMODE_AGENT_MODEL_CRITIC, $K0): the tool check called get_time, not get_weather"
    endpoint '{tools: {"acme/zeta-9000": "garbled"}}'
    both 1
    dep "mcloud-pins: ALAMODE_SESSION_MODEL, $Z0: the tool check called get_weather with arguments that are not a JSON object"
    plain "mcloud-pins: acme/zeta-9000 (ALAMODE_SESSION_MODEL, $Z0): the tool check called get_weather with arguments that are not a JSON object (it said: {city: Paris)"
    endpoint '{tools: {"acme/zeta-9000": "elsewhere"}}'
    both 1
    dep "mcloud-pins: ALAMODE_SESSION_MODEL, $Z0: the tool check called get_weather without city Paris"
    endpoint '{tools: {"acme/omega-2": 400}}'
    both 1
    dep "mcloud-pins: ALAMODE_AGENT_MODEL_VISION, $O0: the tool check answers HTTP 400, so the endpoint refuses a request with tools"
    dep "  fix: point ALAMODE_AGENT_MODEL_VISION at a model that calls tools, $S"
    unanswered '{tools: {"acme/omega-2": 503}}' "ALAMODE_AGENT_MODEL_VISION, $O0: the tool check answers HTTP 503" \
      "point ALAMODE_AGENT_MODEL_VISION at a model that calls tools, $S"
    unanswered '{tools: {"acme/omega-2": 429}}' "ALAMODE_AGENT_MODEL_VISION, $O0: the tool check answers HTTP 429" \
      "point ALAMODE_AGENT_MODEL_VISION at a model that calls tools, $S"

    # Context, only on request: a prompt of 90% of the window less maxTokens
    # at 4 characters a token, opening with the marker.
    endpoint
    run 0 --context
    cp "$T/out" "$T/plain"
    plain 'mcloud-pins (context): acme/zeta-9000: about 1600 prompt tokens, contextWindow 2000...'
    plain 'mcloud-pins (context): acme/omega-2: about 800 prompt tokens, contextWindow 1000...'
    grep -q '^mcloud-pins (context): acme/zeta-9000: ok in [0-9]*s$' "$T/plain" || fail "no context progress"
    row "acme/zeta-9000 yes 200 - ok ok ok $Z"
    row "acme/omega-2 yes 200 ok - ok ok $O"
    row "acme/kappa-7 yes 200 ok ok ok - $K"
    plain 'mcloud-pins: 3 pins served and answering, 2 image checks, 4 reasoning checks, 3 tool checks and 2 context checks passed'
    requests '
      of("context") | length == 2 and all((keys | length) == 3 and budget == 4096)
      and (map([.model, (.messages[0].content | length), has("max_tokens")]) | sort)
        == [["acme/omega-2", 3200, true], ["acme/zeta-9000", 6400, false]]'
    endpoint '{contextLimit: {"acme/zeta-9000": 1000}, context: {"acme/omega-2": "drop"}}'
    run 1 --context
    cp "$T/out" "$T/plain"
    plain "mcloud-pins: acme/zeta-9000 ($Z0): the endpoint rejects a prompt of about 1600 tokens, under the declared contextWindow 2000: HTTP 400 (the endpoint said: maximum context length is 1000 tokens)"
    plain "  fix: lower contextWindow in $Z0 to what the endpoint serves, $S"
    plain "mcloud-pins: acme/omega-2 ($O0): the context check (about 800 tokens, contextWindow 1000) answered without the marker from the prompt's start (it said: There is no marker.), so the endpoint truncates long prompts or the model loses the start"
    plain "  fix: lower contextWindow in $O0 to what the endpoint serves, $S"
    row "acme/zeta-9000 yes 200 - ok ok FAIL $Z"
    grep -q '^mcloud-pins (context): acme/zeta-9000: FAIL in [0-9]*s$' "$T/plain" || fail "no context progress on failure"
    endpoint '{context: {"acme/zeta-9000": 503}}'
    run 1 --context
    cp "$T/out" "$T/plain"
    plain "mcloud-pins: acme/zeta-9000 ($Z0): the context check (about 1600 tokens) answers HTTP 503 (the endpoint said: acme/zeta-9000 cannot take this request)"
    plain "  fix: rerun mcloud-pins --context; if it fails the same way, lower contextWindow in $Z0 to what the endpoint serves, $S"
    run 2 --deploy --context
    run 2 --context --deploy

    # Not listed, and a seat naming a model the catalog lacks.
    endpoint '{served: ["acme/zeta-9000", "acme/omega-2"]}'
    printf '%s\t%s\n' ALAMODE_DELEGATE_MODEL mcloud/acme/nope-1:high >>"$HOME/seats"
    both 1
    dep "mcloud-pins: $K: the endpoint does not list this model"
    dep "  fix: correct the id, or pick a model the endpoint lists, in $K, $S"
    dep 'mcloud-pins: ALAMODE_DELEGATE_MODEL: a seat names this mcloud model, but alamode_models_json has no entry for it, so the engine cannot select it'
    dep "  fix: add an entry for it to alamode_models_json providers.mcloud.models, or point ALAMODE_DELEGATE_MODEL at a catalogued model, $S"
    dep 'mcloud-pins: ALAMODE_DELEGATE_MODEL: the endpoint does not list this model'
    dep "  fix: correct the id, or pick a model the endpoint lists, in ALAMODE_DELEGATE_MODEL, $S"
    dep 'mcloud-pins: 3 problems across 4 pins, each with its fix above'
    plain "mcloud-pins: acme/kappa-7 ($K): the endpoint does not list this model"
    row "acme/kappa-7 NO skip skip skip skip $K"
    row "acme/nope-1 NO skip - skip skip ALAMODE_DELEGATE_MODEL"
    cp "$T/seats.good" "$HOME/seats"

    # Listed, not answering after a retry; no capability check after a
    # failed probe; 429 is the endpoint's own throttle, passes without a
    # retry, and keeps the 5xx probes per-pin problems rather than an
    # outage; a 400 points at the token field.
    endpoint '{text: {"acme/zeta-9000": 503, "acme/omega-2": 500, "acme/kappa-7": 429}}'
    both 1
    requests 'of("text") | group_by(.model) | map([.[0].model, length])
      == [["acme/kappa-7", 2], ["acme/omega-2", 4], ["acme/zeta-9000", 4]]'
    dep "mcloud-pins: $Z: listed, but a one-token completion answers HTTP 503, so nothing serves it"
    dep "  fix: replace the model in $Z, $S, or rerun mcloud-pins once the endpoint serves it"
    dep "mcloud-pins: $O: listed, but a one-token completion answers HTTP 500"
    dep "  fix: replace the model in $O, $S"
    dep 'mcloud-pins: 2 problems across 3 pins, each with its fix above'
    row "acme/omega-2 yes 500 skip - skip $O"
    row "acme/zeta-9000 yes 503 - skip skip $Z"
    row "acme/kappa-7 yes 429 ok ok ok $K"
    endpoint '{text: {"acme/zeta-9000": "000"}}'
    both 1
    dep "mcloud-pins: $Z: a one-token completion got no answer within 60s"
    dep "  fix: rerun mcloud-pins; if it fails the same way, replace the model in $Z, $S"
    dep "  log: $LOG"
    # A 401, a 403, a 5xx or no answer is retried once: a failure that
    # clears passes, one that does not fails.
    endpoint '{text: {"acme/zeta-9000": "flaky000", "acme/omega-2": "flaky401", "acme/kappa-7": "flaky503"}}'
    both 0
    [ "$(cat "$T/deploy")" = "$PASS" ] || fail "a probe failed once did not pass on its retry"
    requests 'of("text") | length == 12'
    [ "$(grep -c '^[0-9:]* probe models\[0\] 000 exit 28 ' "$LOG")" = 2 ] &&
      [ "$(grep -c '^[0-9:]* retry models\[0\] 200 exit 0 ' "$LOG")" = 2 ] ||
      fail "the request log has no hung probe and retry for models[0]"
    endpoint '{text: {"acme/omega-2": 401}}'
    both 1
    dep "mcloud-pins: $O: listed, but a one-token completion answers HTTP 401"
    dep "  fix: replace the model in $O, $S"
    requests 'of("text") | map(select(.model == "acme/omega-2")) | length == 4'
    endpoint '{text: {"acme/omega-2": 400}}'
    both 1
    dep "mcloud-pins: $O: listed, but a one-token completion answers HTTP 400 to max_tokens, the token field the engine sends"
    dep "  fix: if the endpoint takes another token field, set compat.maxTokensField in $O0 to it; otherwise replace the model in $O, $S"

    # The image check: refused, an outage, no answer, the wrong color,
    # nothing.
    endpoint '{image: {"acme/omega-2": 400}}'
    both 1
    dep "mcloud-pins: $O: the image check answers HTTP 400, so the endpoint refuses the image or the request"
    dep "  fix: $SEE"
    dep 'mcloud-pins: 1 problem across 3 pins, each with its fix above'
    plain "mcloud-pins: acme/omega-2 ($O): the image check answers HTTP 400 (the endpoint said: acme/omega-2 cannot take this request), so the endpoint refuses the image or the request"
    row "acme/omega-2 yes 200 FAIL - ok $O"
    unanswered '{image: {"acme/kappa-7": 503}}' "$K: the image check answers HTTP 503" "$SEE_K"
    unanswered '{image: {"acme/kappa-7": 429}}' "$K: the image check answers HTTP 429" "$SEE_K"
    unanswered '{image: {"acme/kappa-7": "000"}}' "$K: the image check got no answer within 120s" "$SEE_K"
    endpoint '{image: {"acme/kappa-7": "red"}}'
    both 1
    dep "mcloud-pins: $K: the image check's reply does not name green, so the endpoint drops the image or the model cannot see it"
    dep "  fix: $SEE_K"
    plain "mcloud-pins: acme/kappa-7 ($K): the image check's reply does not name green (it said: The image is red.), so the endpoint drops the image or the model cannot see it"
    endpoint '{image: {"acme/kappa-7": "greenish"}}'
    both 1
    dep "mcloud-pins: $K: the image check's reply does not name green, so the endpoint drops the image or the model cannot see it"
    endpoint '{image: {"acme/omega-2": "empty"}}'
    both 1
    dep "mcloud-pins: $O: the image check answered 200 with no text (finish_reason length), probably all 1024 tokens spent reasoning"
    dep "  fix: a model that cannot name one color in 1024 tokens starves an image seat: $SEE"
    endpoint

    # The key: MCLOUD_API_KEY, else MCLOUD_API_KEY_COMMAND, else the
    # keyCommand the build baked in.
    MCLOUD_API_KEY= both 2
    dep 'mcloud-pins: no mcloud key: MCLOUD_API_KEY and MCLOUD_API_KEY_COMMAND are unset, and this mcloud-pins was built without a keyCommand'
    dep "  fix: set keyCommand where this host installs mcloud-pins (nix/hosts/<host>/configuration.nix) and deploy; MCLOUD_API_KEY or MCLOUD_API_KEY_COMMAND covers a single run"
    MCLOUD_API_KEY= MCLOUD_API_KEY_COMMAND=false both 2
    dep 'mcloud-pins: the key command printed no key (exit 1): false'
    MCLOUD_API_KEY= MCLOUD_API_KEY_COMMAND='echo test-key' both 0
    MCLOUD_API_KEY= PATH=${baked}/bin:$PATH both 0
    MCLOUD_API_KEY= MCLOUD_API_KEY_COMMAND=false PATH=${baked}/bin:$PATH both 2
    dep 'mcloud-pins: the key command printed no key (exit 1): false'
    MCLOUD_API_KEY=wrong both 2
    dep 'mcloud-pins: GET /models answered HTTP 401, so the endpoint refuses the key'
    dep "  fix: check the key: MCLOUD_API_KEY when set, else what MCLOUD_API_KEY_COMMAND or this host's keyCommand for mcloud-pins prints"

    # The catalog link and what it holds.
    cp ${good} "$T/models.json"
    catalog "$T/models.json"
    both 2
    dep "mcloud-pins: $A/models.json is a link to $T/models.json, not a link into /nix/store, so home-manager did not write it and its baseUrl is not trusted with the key"
    dep '  fix: set hmFoundry.dev.alamode.modelsJsonFile (or modelsJson) for this host and deploy, after moving aside anything else at that path'
    rm "$A/models.json"
    cp ${good} "$A/models.json"
    both 2
    dep "mcloud-pins: $A/models.json is a plain file, not a link into /nix/store, so home-manager did not write it and its baseUrl is not trusted with the key"
    rm "$A/models.json"
    both 2
    dep "mcloud-pins: $A/models.json is missing, not a link into /nix/store, so home-manager did not write it and its baseUrl is not trusted with the key"
    catalog ${dangling}
    both 2
    dep "mcloud-pins: $A/models.json links to ${dangling}, which is not readable JSON"
    dep "  fix: add alamode_models_json, holding the catalog as JSON, $S and deploy, so sops-nix writes the file it points at"
    catalog ${noBaseUrl}
    both 2
    dep 'mcloud-pins: alamode_models_json has no providers.mcloud.baseUrl, so there is no endpoint to check'
    dep "  fix: set providers.mcloud.baseUrl in alamode_models_json $S"
    catalog ${noModels}
    grep -v mcloud/ "$T/seats.good" >"$HOME/seats"
    both 2
    dep 'mcloud-pins: nothing names an mcloud model: alamode_models_json has no providers.mcloud.models and no seat starts with mcloud/'
    dep "  fix: list this host's models in alamode_models_json providers.mcloud.models and point ALAMODE_SESSION_MODEL at one of them, $S"
    cp "$T/seats.good" "$HOME/seats"
    catalog ${good}

    # The listing.
    endpoint '{served: []}'
    both 2
    dep 'mcloud-pins: GET /models answered 200 with no model ids'
    dep "  fix: check that providers.mcloud.baseUrl in alamode_models_json $S is the mcloud API root"
    endpoint '{listing: 404}'
    both 2
    dep 'mcloud-pins: GET /models answered HTTP 404, so the baseUrl is not an OpenAI-compatible API root'
    endpoint '{listing: 418}'
    both 2
    dep 'mcloud-pins: GET /models answered HTTP 418'

    # An endpoint that does not answer at all fails a run by hand, and only
    # warns under --deploy, which runs after the switch has landed.
    outage() { # <endpoint> <what> <if it keeps failing>
      endpoint "$1"
      run 0 --deploy
      if grep -qiE 'acme|zeta|omega|kappa|lambda|sigma|tau|nope' "$T/out"; then fail "--deploy printed a fixture id"; fi
      cp "$T/out" "$T/deploy"
      run 2
      cp "$T/out" "$T/plain"
      dep "mcloud-pins: warning: $2, so no pin was checked"
      dep "  fix: rerun mcloud-pins once the endpoint answers; if it keeps failing, $3"
      plain "mcloud-pins: $2"
      plain "  fix: rerun mcloud-pins; if it fails the same way, $3"
      if grep -q 'served and answering' "$T/deploy"; then fail "outage $1: --deploy claimed a pass"; fi
    }
    NET="check the network, then providers.mcloud.baseUrl in alamode_models_json $S"
    outage '{listing: 502}' 'GET /models answered HTTP 502' "$NET"
    outage '{listing: 429}' 'GET /models answered HTTP 429' "$NET"
    outage '{listing: "000"}' 'GET /models at the mcloud baseUrl got no answer within 30s' "$NET"
    # So is every listed pin's probe getting no answer or a 5xx while
    # GET /models answers. A probe and its retry per pin is all a run sends.
    # One answer of any other kind keeps them per-pin problems: a 429 (the
    # probe case above) or a 401.
    COMPLETIONS="the endpoint is failing completions while GET /models accepts the key at this baseUrl, so wait it out rather than change this host's config"
    outage '{text: {"acme/zeta-9000": 500, "acme/omega-2": 500, "acme/kappa-7": 500}}' \
      'GET /models answers, but a one-token completion to every listed pin got HTTP 500' "$COMPLETIONS"
    requests 'length == 12 and all(kind == "text")'
    outage '{text: {"acme/zeta-9000": "000", "acme/omega-2": "000", "acme/kappa-7": "000"}}' \
      'GET /models answers, but a one-token completion to every listed pin got no answer within 60s' "$COMPLETIONS"
    outage '{text: {"acme/zeta-9000": 503, "acme/omega-2": 500, "acme/kappa-7": "000"}}' \
      'GET /models answers, but a one-token completion to every listed pin got HTTP 500/503 or no answer within 60s' "$COMPLETIONS"
    endpoint '{text: {"acme/zeta-9000": 500, "acme/omega-2": 500, "acme/kappa-7": 401}}'
    both 1
    dep "mcloud-pins: $K: listed, but a one-token completion answers HTTP 401"
    dep "mcloud-pins: $O: listed, but a one-token completion answers HTTP 500"
    dep 'mcloud-pins: 3 problems across 3 pins, each with its fix above'
    endpoint

    # alamode-seats: a failed list, no sops file to name, absent.
    rm "$HOME/seats"
    mkdir "$HOME/seats"
    both 2
    dep 'mcloud-pins: alamode-seats list failed, so no seat was checked'
    dep '  fix: run alamode-seats check --deploy and fix what it reports'
    rmdir "$HOME/seats"
    cp "$T/seats.good" "$HOME/seats"
    rm "$HOME/source"
    endpoint '{image: {"acme/kappa-7": "red"}}'
    both 1
    dep "  fix: remove \"image\" from input in $K0, or point ALAMODE_AGENT_MODEL_CRITIC, ALAMODE_CLASSIFY_MODEL at a model that sees images, in this host's sops file"
    rm "$T/bin/alamode-seats"
    endpoint '{image: {"acme/omega-2": "red"}}'
    both 1
    dep "  fix: remove \"image\" from input in $O0, in this host's sops file"
    endpoint
    both 0
    dep 'mcloud-pins: 3 pins served and answering, 2 image checks, 0 reasoning checks and 0 tool checks passed'

    # The log keeps its last 2000 lines across runs.
    endpoint
    seq 2500 >"$LOG"
    run 0 --deploy
    [ "$(grep -cx '[0-9]*' "$LOG")" -le 2000 ] || fail "the request log was not trimmed"

    run 2 --verbose
    grep -qxF 'usage: mcloud-pins [--deploy | --context]' "$T/out" || fail "no usage line"

    touch "$out"
  ''
