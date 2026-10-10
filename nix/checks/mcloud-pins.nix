# Flake check for mcloud-pins (nix/pkgs/mcloud-pins) against a stub
# endpoint: the listing and one-token probes, the image capability check and
# the request it sends, every early failure, a fix line under every failure,
# and that --deploy output names no fixture id.
#
# The fixtures use made-up ids. The stub endpoint takes its behaviour from
# ~/endpoint.json: `served` ids, the listing's HTTP status, and per id a
# status or reply for `text` (one-token) and `image` requests.
{ pkgs }:
let
  baseUrl = "http://mcloud.invalid/v1";
  models = [
    {
      id = "acme/zeta-9000";
      input = [ "text" ];
    }
    {
      id = "acme/omega-2";
      input = [
        "text"
        "image"
      ];
    }
    {
      id = "acme/kappa-7";
      input = [
        "text"
        "image"
      ];
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
    reply() { # <content> <finish_reason>
      answer 200 "$($jq -nc --arg c "$1" --arg f "$2" \
        '{choices: [{message: {role: "assistant", content: $c}, finish_reason: $f}]}')"
    }
    [ "$auth" = "Authorization: Bearer test-key" ] || answer 401 '{"error": {"message": "bad key"}}'
    case $url in
    ${baseUrl}/models)
      answer "$($jq -r '.listing // 200' "$E")" "$($jq -c '{data: [.served[] | {id: ., object: "model"}]}' "$E")"
      ;;
    ${baseUrl}/chat/completions)
      printf '%s\n' "$data" >>"$HOME/requests"
      model=$($jq -r .model <<<"$data")
      if $jq -e '.messages[0].content | type == "array"' <<<"$data" >/dev/null; then
        mode=$($jq -r --arg m "$model" '.image[$m] // "green"' "$E")
      else
        mode=$($jq -r --arg m "$model" '.text[$m] // "ok"' "$E")
      fi
      case $mode in
      ok) reply h length ;;
      green) reply Green. stop ;;
      greenish) reply greenish stop ;;
      red) reply $'The image is\nred.' stop ;;
      empty) reply "" length ;;
      *) answer "$mode" "$($jq -nc --arg m "$model" '{error: {message: ($m + " cannot take this request")}}')" ;;
      esac
      ;;
    *) answer 404 '{}' ;;
    esac
  '';

  piSeats = pkgs.writeShellScript "pi-seats" ''
    case "$*" in
    list) cat "$HOME/seats" ;;
    source) cat "$HOME/source" 2>/dev/null || true ;;
    *) exit 2 ;;
    esac
  '';

  mcloud-pins = pkgs.mcloud-pins.override { inherit curl; };
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
    run() { # <exit> [arg]: mcloud-pins into $T/out; every failure line has a fix line under it
      want=$1
      shift
      rc=0
      mcloud-pins "$@" >"$T/out" 2>&1 || rc=$?
      [ "$rc" = "$want" ] || fail "mcloud-pins $*: exit $rc, wanted $want"
      [ "$want" = 0 ] || awk 'want && !/^  fix: / { exit 1 }
        { want = /^mcloud-pins: / && !/, each with its fix above$/ } END { exit want }' "$T/out" ||
        fail "mcloud-pins $*: a failure without a fix line"
    }
    both() { # <exit>: --deploy into $T/deploy, which names no fixture id, and plain into $T/plain
      run "$1" --deploy
      if grep -qiE 'acme|zeta|omega|kappa|sigma|tau|nope' "$T/out"; then fail "--deploy printed a fixture id"; fi
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
      jq -n '{served: ["acme/zeta-9000", "acme/omega-2", "acme/kappa-7", "acme/tau-5"]}'" + ''${1:-null}" \
        >"$HOME/endpoint.json"
    }
    catalog() {
      ln -sfn "$1" "$A/models.json"
    }

    T=$TMPDIR/mp
    export HOME=$T/home
    A=$HOME/.pi/agent
    mkdir -p "$A" "$T/bin"
    ln -s ${piSeats} "$T/bin/pi-seats"
    export PATH=$T/bin:$PATH
    export MCLOUD_API_KEY=test-key
    unset MCLOUD_API_KEY_COMMAND
    printf '%s\n' nix/secrets/fake.yaml >"$HOME/source"
    printf '%s\t%s\n' \
      PI_SESSION_MODEL mcloud/acme/zeta-9000:xhigh \
      PI_AGENT_MODEL_VISION mcloud/acme/omega-2 \
      PI_SPAWN_MODEL othercloud/acme/sigma-3 >"$HOME/seats"
    catalog ${good}
    S='in nix/secrets/fake.yaml'
    Z='PI_SESSION_MODEL, pi_models_json providers.mcloud.models[0]'
    O='PI_AGENT_MODEL_VISION, pi_models_json providers.mcloud.models[1]'
    K='pi_models_json providers.mcloud.models[2]'
    SEE="remove \"image\" from input in pi_models_json providers.mcloud.models[1], or point PI_AGENT_MODEL_VISION at a model that sees images, $S"
    SEE_K="remove \"image\" from input in $K, $S"

    # All pass: one line at deploy, the table otherwise.
    endpoint
    both 0
    [ "$(cat "$T/deploy")" = 'mcloud-pins: 3 pins served and answering, 2 image checks passed' ] ||
      fail "deploy success line"
    row "acme/kappa-7 yes 200 ok $K"
    row "acme/omega-2 yes 200 ok $O"
    row "acme/zeta-9000 yes 200 - $Z"
    plain 'served, unpinned: acme/tau-5'
    plain 'mcloud-pins: 3 pins served and answering, 2 image checks passed'

    # What went out: one-token probes, then per image model one request
    # carrying the known image, with no reasoning parameter. othercloud's
    # image model is not mcloud's to check.
    jq -se --arg prompt 'What color fills this image? Reply with one lowercase word.' '
      (map(select(.messages[0].content | type == "string")) | length == 6 and all(.max_tokens == 1))
      and (map(select(.messages[0].content | type == "array")) as $img
        | ($img | length) == 4
        and ($img | map(.model) | unique) == ["acme/kappa-7", "acme/omega-2"]
        and all($img[]; keys == ["max_tokens", "messages", "model"] and .max_tokens == 1024
          and .messages == [{role: "user", content: [{type: "text", text: $prompt},
            {type: "image_url", image_url: {url: .messages[0].content[1].image_url.url}}]}]
          and (.messages[0].content[1].image_url.url | startswith("data:image/png;base64,"))))
    ' "$HOME/requests" >/dev/null || fail "requests: $(cat "$HOME/requests")"
    printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0@\0\0\0@' >"$T/head"
    jq -r 'select(.messages[0].content | type == "array") | .messages[0].content[1].image_url.url' "$HOME/requests" |
      sed -n 's/^data:image\/png;base64,//; 1p' | base64 -d | cmp -n 24 - "$T/head" ||
      fail "the image is not a 64x64 PNG"
    rm "$HOME/requests"

    # Not listed, and a seat naming a model the catalog lacks.
    endpoint '{served: ["acme/zeta-9000", "acme/omega-2"]}'
    cp "$HOME/seats" "$T/seats"
    printf '%s\t%s\n' PI_DELEGATE_MODEL mcloud/acme/nope-1:high >>"$HOME/seats"
    both 1
    dep "mcloud-pins: $K: the endpoint does not list this model"
    dep "  fix: correct the id, or pick a model the endpoint lists, in $K, $S"
    dep 'mcloud-pins: PI_DELEGATE_MODEL: a seat names this mcloud model, but pi_models_json has no entry for it, so pi cannot select it'
    dep "  fix: add an entry for it to pi_models_json providers.mcloud.models, or point PI_DELEGATE_MODEL at a catalogued model, $S"
    dep 'mcloud-pins: PI_DELEGATE_MODEL: the endpoint does not list this model'
    dep "  fix: correct the id, or pick a model the endpoint lists, in PI_DELEGATE_MODEL, $S"
    dep 'mcloud-pins: 3 problems across 4 pins, each with its fix above'
    plain "mcloud-pins: acme/kappa-7 ($K): the endpoint does not list this model"
    row "acme/kappa-7 NO skip skip $K"
    row "acme/nope-1 NO skip - PI_DELEGATE_MODEL"
    mv "$T/seats" "$HOME/seats"

    # Listed, not answering; no image check after a failed probe; 429 is
    # the endpoint's own throttle and passes.
    endpoint '{text: {"acme/zeta-9000": 503, "acme/omega-2": 500, "acme/kappa-7": 429}}'
    both 1
    dep "mcloud-pins: $Z: listed, but a one-token completion answers HTTP 503, so nothing serves it"
    dep "  fix: replace the model in $Z, $S, or rerun mcloud-pins once the endpoint serves it"
    dep "mcloud-pins: $O: listed, but a one-token completion answers HTTP 500"
    dep "  fix: replace the model in $O, $S"
    dep 'mcloud-pins: 2 problems across 3 pins, each with its fix above'
    row "acme/omega-2 yes 500 skip $O"
    row "acme/kappa-7 yes 429 ok $K"
    endpoint '{text: {"acme/zeta-9000": "000"}}'
    both 1
    dep "mcloud-pins: $Z: a one-token completion got no answer within 60s"
    dep "  fix: rerun mcloud-pins; if it fails the same way, replace the model in $Z, $S"

    # The image check: refused, an outage, the wrong color, nothing.
    endpoint '{image: {"acme/omega-2": 400}}'
    both 1
    dep "mcloud-pins: $O: the image check answers HTTP 400, so the endpoint refuses the image or the request"
    dep "  fix: $SEE"
    dep 'mcloud-pins: 1 problem across 3 pins, each with its fix above'
    plain "mcloud-pins: acme/omega-2 ($O): the image check answers HTTP 400 (the endpoint said: acme/omega-2 cannot take this request), so the endpoint refuses the image or the request"
    row "acme/omega-2 yes 200 FAIL $O"
    endpoint '{image: {"acme/kappa-7": 503}}'
    both 1
    dep "mcloud-pins: $K: the image check answers HTTP 503"
    dep "  fix: rerun mcloud-pins; if it fails the same way, $SEE_K"
    endpoint '{image: {"acme/kappa-7": "000"}}'
    both 1
    dep "mcloud-pins: $K: the image check got no answer within 120s"
    dep "  fix: rerun mcloud-pins; if it fails the same way, $SEE_K"
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

    # The key.
    MCLOUD_API_KEY= both 2
    dep 'mcloud-pins: no mcloud key: MCLOUD_API_KEY and MCLOUD_API_KEY_COMMAND are both unset'
    dep "  fix: set MCLOUD_API_KEY_COMMAND to a command that prints the key (home.sessionVariables in this host's home.nix), or open a new shell if a deploy set it after this one started"
    MCLOUD_API_KEY= MCLOUD_API_KEY_COMMAND=false both 2
    dep 'mcloud-pins: MCLOUD_API_KEY_COMMAND printed no key (exit 1)'
    MCLOUD_API_KEY= MCLOUD_API_KEY_COMMAND='echo test-key' both 0
    MCLOUD_API_KEY=wrong both 2
    dep 'mcloud-pins: GET /models answered HTTP 401, so the endpoint refuses the key'
    dep '  fix: check the key MCLOUD_API_KEY_COMMAND prints (or MCLOUD_API_KEY, which wins when set)'

    # The catalog link and what it holds.
    cp ${good} "$T/models.json"
    catalog "$T/models.json"
    both 2
    dep "mcloud-pins: $A/models.json is a link to $T/models.json, not a link into /nix/store, so home-manager did not write it and its baseUrl is not trusted with the key"
    dep '  fix: set hmFoundry.dev.pi-coding-agent.modelsJsonFile (or modelsJson) for this host and deploy, after moving aside anything else at that path'
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
    dep "  fix: add pi_models_json, holding the catalog as JSON, $S and deploy, so sops-nix writes the file it points at"
    catalog ${noBaseUrl}
    both 2
    dep 'mcloud-pins: pi_models_json has no providers.mcloud.baseUrl, so there is no endpoint to check'
    dep "  fix: set providers.mcloud.baseUrl in pi_models_json $S"
    catalog ${noModels}
    cp "$HOME/seats" "$T/seats"
    grep -v mcloud/ "$T/seats" >"$HOME/seats"
    both 2
    dep 'mcloud-pins: nothing names an mcloud model: pi_models_json has no providers.mcloud.models and no seat starts with mcloud/'
    dep "  fix: list this host's models in pi_models_json providers.mcloud.models and point PI_SESSION_MODEL at one of them, $S"
    mv "$T/seats" "$HOME/seats"
    catalog ${good}

    # The listing.
    endpoint '{served: []}'
    both 2
    dep 'mcloud-pins: GET /models answered 200 with no model ids'
    dep "  fix: check that providers.mcloud.baseUrl in pi_models_json $S is the mcloud API root"
    endpoint '{listing: 404}'
    both 2
    dep 'mcloud-pins: GET /models answered HTTP 404, so the baseUrl is not an OpenAI-compatible API root'
    endpoint '{listing: 502}'
    both 2
    dep 'mcloud-pins: GET /models answered HTTP 502'
    dep "  fix: rerun mcloud-pins; if it fails the same way, check providers.mcloud.baseUrl in pi_models_json $S"
    endpoint '{listing: "000"}'
    both 2
    dep 'mcloud-pins: GET /models at the mcloud baseUrl got no answer within 30s'
    endpoint

    # pi-seats: a failed list, no sops file to name, absent.
    mv "$HOME/seats" "$T/seats"
    mkdir "$HOME/seats"
    both 2
    dep 'mcloud-pins: pi-seats list failed, so no seat was checked'
    dep '  fix: run pi-seats check --deploy and fix what it reports'
    rmdir "$HOME/seats"
    mv "$T/seats" "$HOME/seats"
    rm "$HOME/source"
    endpoint '{image: {"acme/kappa-7": "red"}}'
    both 1
    dep "  fix: remove \"image\" from input in $K, in this host's sops file"
    rm "$T/bin/pi-seats"
    endpoint '{image: {"acme/omega-2": "red"}}'
    both 1
    dep "  fix: remove \"image\" from input in pi_models_json providers.mcloud.models[1], in this host's sops file"
    endpoint
    both 0
    dep 'mcloud-pins: 3 pins served and answering, 2 image checks passed'

    run 2 --verbose
    grep -qxF 'usage: mcloud-pins [--deploy]' "$T/out" || fail "no usage line"

    touch "$out"
  ''
