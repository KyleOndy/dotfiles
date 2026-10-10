# Real-pi end-to-end check for the extension layer the grants design leans on.
#
# pi-coding-agent.nix exercises the wrapper's decisions with a stubbed `pi`
# under PI_DEBUG=plan: it can prove what the wrapper would export, but never
# that anything reaches a model. This check runs the real binary against a
# loopback dump provider and asserts on the requests pi actually sends, which
# is the layer where grants guidance can vanish: the wrapper can export
# PI_GRANTS correctly while the guidance never reaches the prompt.
#
# Covered, each as a request the dump provider captures:
#   - grants.ts delivers carried docs and the missing-grants menu as prompt
#     sections, and a second extension's section survives in the same run:
#     sections compose (a return-based delivery drops every other section
#     from the prompt, and this pins that the sections path does not);
#   - secret-guard lets jq-style accessor tokens (.key) and regex-escaped
#     variants (\.key) through in bash commands, while `cat .env` stays
#     blocked;
#   - refusal-guard appends its ask-don't-work-around note to a bash result
#     carrying a sandbox refusal signature.
# Plus the wrapper's envGrantGates decisions, asserted in plan mode like the
# rest of pi-coding-agent.nix's coverage: skip when the grant is not carried,
# resolve when it is, scrub a caller-shell copy of a gated var, and refuse an
# unknown gate name.
#
# The real binary also means this check is heavier than the plan-mode ones and
# inherits the platform: on linux, pi inside the nix build sandbox may need
# nested user namespaces for the wrapper legs, which most kernels allow but
# not all. The darwin hosts are the primary audience.
{ pkgs }:
let
  inherit (pkgs) lib;
  realPi = lib.getExe pkgs.llm-agents.pi;

  extDir = ../modules/hm_modules/dev/pi/extensions;

  # Synthetic grant docs with headings no real grant file uses, so the
  # assertions pin the mechanism without depending on host prose. Copied
  # into the fixture agent dir under grants.ts's <grant-name>.md convention.
  mkGrant =
    name: heading:
    pkgs.writeText "grant-${name}" ''
      # ${heading}

      Fixture body for the ${name} grant, e2e check only. ${heading} again
      for a second assertion point.
    '';
  grantNix = mkGrant "nix" "test nix grant heading";
  grantKagi = mkGrant "kagi" "test kagi grant heading";
  grantSsh = mkGrant "ssh-agent" "test ssh-agent grant heading";

  # Loopback dump provider: appends every request body to $CAPTURE_FILE and
  # answers with a canned completion. With SCRIPTED_RESPONSE set, the first
  # request gets that payload verbatim (tool_calls included) so a bash tool
  # call can be driven deterministically; later requests get the default.
  server = pkgs.writeText "pi-e2e-server.py" ''
    import json, os, sys
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    CAPTURE = os.environ.get("CAPTURE_FILE", "/dev/null")
    SCRIPTED = os.environ.get("SCRIPTED_RESPONSE", "")
    count = {"n": 0}

    def payload(req):
        if SCRIPTED and count["n"] == 1:
            return json.loads(SCRIPTED)
        return {
            "id": "chatcmpl-dump", "object": "chat.completion", "created": 0,
            "model": req.get("model", "probe"),
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }

    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            count["n"] += 1
            n = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(n)
            try:
                with open(CAPTURE, "ab") as f:
                    f.write(body + b"\n")
            except Exception as e:
                sys.stderr.write(f"capture failed: {e} (path {CAPTURE}, cwd {os.getcwd()})\n")
                sys.stderr.flush()
            req = json.loads(body)
            p = payload(req)
            if req.get("stream"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                msg = p["choices"][0]["message"]
                head = dict(p, object="chat.completion.chunk",
                            choices=[{"index": 0, "delta": {"role": "assistant", "content": msg.get("content") or ""}, "finish_reason": None}])
                self.wfile.write(b"data: " + json.dumps(head).encode() + b"\n\n")
                for i, tc in enumerate(msg.get("tool_calls") or []):
                    chunk = dict(p, object="chat.completion.chunk",
                                 choices=[{"index": 0, "delta": {"role": "assistant", "tool_calls": [{"index": i, "id": tc["id"], "type": "function", "function": tc["function"]}]}, "finish_reason": None}])
                    self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
                end = dict(p, object="chat.completion.chunk",
                           choices=[{"index": 0, "delta": {}, "finish_reason": "stop"}])
                self.wfile.write(b"data: " + json.dumps(end).encode() + b"\n\n")
                self.wfile.write(b"data: [DONE]\n\n")
            else:
                data = json.dumps(p).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        def log_message(self, *a):
            pass

    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
  '';

  # Second extension for the composition assertion: writes a section of its
  # own in the same run grants.ts writes two, and the carried run asserts
  # both survive together.
  probeExt = pkgs.writeText "pi-e2e-probe.ts" ''
    import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

    export default function (pi: ExtensionAPI) {
      pi.on("before_agent_start", async (event) => {
        event.systemPromptOptions.sections.probe_marker = "PROBE_MARKER_18765";
      });
    }
  '';

  modelsJson = pkgs.writeText "pi-e2e-models.json" (
    builtins.toJSON {
      providers.dump = {
        baseUrl = "http://127.0.0.1:18765/v1";
        api = "openai-completions";
        apiKey = "dummy";
        models = [
          {
            id = "probe";
            name = "Probe";
            contextWindow = 8192;
            maxTokens = 1024;
          }
        ];
      };
    }
  );

  wrapperGated = pkgs.pi-wrapper.override {
    realPiBin = realPi;
    envFromCommands = {
      KAGI_API_KEY = "echo gated-secret-value";
      TEST_PLAIN = "echo plain-value";
    };
    envGrantGates = {
      KAGI_API_KEY = "kagi";
    };
    networkBundles = {
      kagi.domains = [ "kagi.com" ];
    };
  };
  wrapperBadGate = pkgs.pi-wrapper.override {
    realPiBin = realPi;
    envFromCommands = {
      BAD_GATE_VAR = "echo x";
    };
    envGrantGates = {
      BAD_GATE_VAR = "nonexistent-grant";
    };
  };
in
pkgs.runCommand "pi-e2e-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.jq
      pkgs.gnugrep
      pkgs.coreutils
    ];
    # The dump provider listens on 127.0.0.1, which a sandboxed darwin build
    # may bind only when it asks.
    __darwinAllowLocalNetworking = true;
  }
  ''
        fail() { echo "FAIL: $1" >&2; exit 1; }
        # shellcheck disable=SC2154 # ready is assigned in the loop below

        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" agent/grants
        cp ${grantNix} agent/grants/nix.md
        cp ${grantKagi} agent/grants/kagi.md
        cp ${grantSsh} agent/grants/ssh-agent.md
        cp ${modelsJson} agent/models.json
        mkdir -p captures

        sysp() { jq -r '.messages[0].content' "captures/$1.jsonl"; }
        toolres() {
          jq -rs '[ .[] | .messages[] | select(.role == "tool") ] | last
                  | .content | if type == "array" then map(.text // "") | join("\n") else . end' "captures/$1.jsonl"
        }
        start_server() {
          : > captures/current.jsonl
          # Distinctive port: nix's darwin build sandbox shares the host's
          # loopback, so anything already bound on a common port answers instead
          # of this server and the capture stays empty while pi still gets a
          # canned reply from the wrong one.
          SCRIPTED_RESPONSE="$1" CAPTURE_FILE="$PWD/captures/current.jsonl" \
            python3 ${server} 18765 >server.log 2>&1 &
          SERVER_PID=$!
          # Readiness gate, not a fixed sleep: pi's first request must not
          # race the server's bind on a slow builder. A bare TCP connect does
          # not POST, so it consumes neither the one-shot scripted response nor
          # the capture.
          ready=0
          for _ in $(seq 1 40); do
            python3 -c 'import socket,sys
    s = socket.socket()
    s.settimeout(0.3)
    sys.exit(0 if s.connect_ex(("127.0.0.1", 18765)) == 0 else 1)' && ready=1 && break
            sleep 0.2
          done
          [ "$ready" = 1 ] || fail "dump server never became ready; log: $(tail -c 300 server.log)"
        }
        stop_server() { kill $SERVER_PID 2>/dev/null || true; sleep 1; }
        run_pi() { # tag [extra args...]
          local tag=$1; shift
          PI_CODING_AGENT_DIR="$PWD/agent" PI_GRANTS="nix,kagi" \
          PI_AVAILABLE_GRANTS="kagi,nix,ssh-agent" PI_OFFLINE=1 \
            ${realPi} --no-extensions "$@" \
              --provider dump --model dump/probe --thinking off \
              -nc -ns -np -na --offline --mode text --print "hi" \
              >"out-$tag" 2>"err-$tag" || fail "pi exited nonzero ($tag): $(tail -c 200 err-$tag)"
          cp captures/current.jsonl "captures/$tag.jsonl"
        }

        # ---- grants.ts: sections compose, both branches deliver ----
        # A second probe extension writes its own section in the same run, so
        # composition is asserted here, not taken on faith in pi's pipeline: a
        # return-based delivery drops every other extension's section from the
        # prompt, and this pins that the sections path does not.
        start_server ""
        PI_CODING_AGENT_DIR="$PWD/agent" PI_GRANTS="nix,kagi" \
          PI_AVAILABLE_GRANTS="kagi,nix,ssh-agent" PI_OFFLINE=1 \
          ${realPi} --no-extensions -e ${extDir}/grants.ts -e ${probeExt} \
            --provider dump --model dump/probe --thinking off \
            -nc -ns -np -na --offline --mode text --print "hi" \
            >out-carried 2>err-carried || fail "pi exited nonzero (carried)"
        cp captures/current.jsonl captures/carried.jsonl
        c=$(sysp carried)
        echo "$c" | grep -q '<granted_capabilities>' \
          || fail "carried run missing granted_capabilities section"
        echo "$c" | grep -q 'test nix grant heading' || fail "carried run missing nix grant doc"
        echo "$c" | grep -q 'PROBE_MARKER_18765' \
          || fail "carried run dropped a second extension's section; sections do not compose"
        echo "$c" | grep -q 'test kagi grant heading' || fail "carried run missing kagi grant doc"
        echo "$c" | grep -q '<missing_grants>' || fail "carried run missing missing_grants section"
        echo "$c" | grep -q -- '- ssh-agent (test ssh-agent grant heading)' \
          || fail "carried run missing ssh-agent in the missing list"
        echo "$c" | grep -q -- '- kagi ' && fail "missing list includes a carried grant"
        stop_server

        # ---- secret-guard: accessor tokens pass, .env still blocks ----
        script() { # bash command -> scripted tool_call response
          jq -cn --arg command "$1" '{id:"x",object:"chat.completion",created:0,model:"probe",choices:[{index:0,message:{role:"assistant",content:null,tool_calls:[{id:"call_1",type:"function",function:{name:"bash",arguments:({"command": $command} | tojson)}}],finish_reason:"tool_calls"}}],usage:{prompt_tokens:1,completion_tokens:1,total_tokens:2}}'
        }
        exts_secret="-e ${extDir}/secret-guard.ts"

        start_server "$(script "echo check .key")"
        run_pi sg-fp $exts_secret
        r=$(toolres sg-fp)
        echo "$r" | grep -q 'check .key' || fail "secret-guard blocked the .key accessor token: $r"
        echo "$r" | grep -q 'secret-guard:' && fail "secret-guard fired on .key accessor: $r"
        stop_server

        start_server "$(script "echo check \\.key")"
        run_pi sg-escape $exts_secret
        r=$(toolres sg-escape)
        echo "$r" | grep -q 'secret-guard:' && fail "secret-guard fired on regex-escaped \.key: $r"
        stop_server

        start_server "$(script "cat .env")"
        run_pi sg-env $exts_secret
        r=$(toolres sg-env)
        echo "$r" | grep -q 'secret-guard: blocked' || fail "cat .env was not blocked: $r"
        stop_server

        # ---- refusal-guard: names the sandbox on a refusal signature ----
        start_server "$(script "echo 'ssh: connect to host: Operation not permitted'; exit 1")"
        run_pi rg-fire -e ${extDir}/refusal-guard.ts
        r=$(toolres rg-fire)
        echo "$r" | grep -q '\[refusal-guard\]' || fail "refusal-guard did not annotate the refused result: $r"
        echo "$r" | grep -q 'ssh-agent' || fail "refusal-guard note missing grant names: $r"
        stop_server

        start_server "$(script "echo 'docs/example.md: Operation not permitted'")"
        run_pi rg-clean -e ${extDir}/refusal-guard.ts
        r=$(toolres rg-clean)
        echo "$r" | grep -q 'refusal-guard' && fail "refusal-guard fired on a clean result: $r"
        stop_server

        # ---- wrapper: envGrantGates (plan mode, like pi-coding-agent.nix) ----
        captured=$(PI_DEBUG=plan KAGI_API_KEY=leaked-from-shell ${wrapperGated}/bin/pi -- x 2>&1)
        echo "$captured" | grep -q 'PI_PLAN_ENV_SKIPPED: KAGI_API_KEY (gate: kagi, not carried)' \
          || fail "ungated run resolved gated var. captured=$captured"
        echo "$captured" | grep -q 'PI_PLAN_ENV: KAGI_API_KEY' \
          && fail "ungated run resolved the gated KAGI_API_KEY. captured=$captured"
        echo "$captured" | grep -q 'PI_PLAN_ENV: TEST_PLAIN' \
          || fail "ungated run skipped an ungated resolver. captured=$captured"
        echo "$captured" | grep -q 'PI_PLAN_SCRUBBED: KAGI_API_KEY' \
          || fail "caller-shell copy of a gated var survived the scrub. captured=$captured"

        captured=$(PI_DEBUG=plan KAGI_API_KEY=leaked-from-shell ${wrapperGated}/bin/pi --allow-kagi -- x 2>&1)
        echo "$captured" | grep -q 'PI_PLAN_ENV: KAGI_API_KEY=echo gated-secret-value' \
          || fail "granted run did not resolve the gated var. captured=$captured"
        echo "$captured" | grep -q 'PI_PLAN_SCRUBBED: KAGI_API_KEY' \
          && fail "granted run scrubbed the resolver's own var. captured=$captured"

        if captured=$(PI_DEBUG=plan ${wrapperBadGate}/bin/pi -- x 2>&1); then
          fail "unknown gate name did not abort startup. captured=$captured"
        fi
        echo "$captured" | grep -q "envGrantGates names 'nonexistent-grant'" \
          || fail "unknown gate refusal lacks the gate name. captured=$captured"

        touch "$out"
  ''
