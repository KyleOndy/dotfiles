# Real Pi and synthetic providers exercise extension registration, shared result
# classification, scoped credentials, and the tools Pi exposes to each role.
{ pkgs }:
let
  inherit (pkgs) lib;
  realPi = lib.getExe pkgs.llm-agents.pi;
  kagi = pkgs.callPackage ../pkgs/kagi { };

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

  runtimeProbe = pkgs.writeText "pi-runtime-probe.ts" ''
    import assert from "node:assert/strict";
    import { readFileSync } from "node:fs";
    import { classifyResult } from "${extDir}/task.ts";
    import stallGuard from "${extDir}/stall-guard.ts";
    import refusalGuard from "${extDir}/refusal-guard.ts";
    import resumeHint from "${extDir}/resume-hint.ts";
    import coordinator from "${extDir}/coordinator.ts";

    export default async function () {
      const cases = JSON.parse(readFileSync("${../pkgs/pi-session/result-fixtures.json}", "utf8"));
      for (const c of cases) {
        const result = classifyResult(c.events, c.exit_code ?? 0, c.aborted ?? false, c.timed_out ?? false);
        assert.equal(result.state, c.expected.state, c.name);
        assert.equal(result.text, c.expected.text, c.name);
      }
      const hooks: Record<string, Function> = {};
      let tool: any;
      const api = {
        on: (name: string, fn: Function) => hooks[name] = fn,
        registerTool: (value: any) => tool = value,
        registerCommand: () => {}, events: { emit: () => {} }, sendMessage: () => {},
      };
      const ctx = {
        cwd: process.cwd(), mode: "tui", hasUI: false,
        sessionManager: { getSessionId: () => "fixture", getSessionFile: () => undefined },
      };
      stallGuard(api as any);
      const command = "test -n \"$SHELL_PREFIX_FIXTURE\" && printf '%s' \"$BASH_VERSION\"";
      for (const mode of ["tui", "print"]) {
        const result = await tool.execute("fixture", { command }, undefined, undefined, { ...ctx, mode });
        assert.match(result.content[0].text, /^5\./, "Configured Bash and command prefix in " + mode);
      }
      refusalGuard(api as any);
      const success = { toolName: "bash", isError: false, content: [{ type: "text", text: "Operation not permitted" }] };
      hooks.tool_result(success, ctx);
      assert.equal(success.content.length, 1);
      const failure = { ...success, isError: true, content: [...success.content] };
      hooks.tool_result(failure, ctx);
      assert.equal(failure.content.length, 2, "Successful quoted text must not consume the failure hint");
      resumeHint(api as any);
      let hint = "";
      const write = process.stdout.write;
      Object.defineProperty(process.stdout, "isTTY", { value: true, configurable: true });
      process.stdout.write = ((text: string) => { hint += text; return true; }) as any;
      process.env.PI_SESSION_ID = "trusted-session-123";
      hooks.session_shutdown({ reason: "quit" }, { ...ctx, hasUI: true });
      assert.match(hint, /pi --resume-session trusted-session-123/);
      hint = "";
      process.env.PI_SESSION_ID = "untrusted;command";
      hooks.session_shutdown({ reason: "quit" }, { ...ctx, hasUI: true });
      assert.equal(hint, "");
      process.stdout.write = write;
      const tools: any[] = [];
      const coordApi = { ...api, registerTool: (value: any) => tools.push(value) };
      delete process.env.PI_COORD_SOCKET;
      delete process.env.PI_COORD_TOKEN;
      process.env.PI_COORD_ROLE = "main";
      coordinator(coordApi as any);
      assert.equal(tools.length, 0, "No tools without broker authority");
      process.env.PI_COORD_SOCKET = "/nonexistent/synthetic-broker.sock";
      process.env.PI_COORD_TOKEN = "synthetic-capability";
      coordinator(coordApi as any);
      const spawn = tools.find((entry) => entry.name === "spawn_agent");
      assert.ok(spawn, "Main role registers spawn_agent");
      assert.deepEqual(spawn.parameters.properties.thinking.anyOf.map((entry: any) => entry.const), ["off", "minimal", "low", "medium", "high", "xhigh", "max"]);
      tools.length = 0;
      process.env.PI_COORD_ROLE = "child";
      coordinator(coordApi as any);
      assert.deepEqual(tools.map((entry) => entry.name).sort(), ["ask_coordinator", "export_commits", "report_result"]);
      tools.length = 0;
      process.env.FORGE_INSTANCE = "1";
      coordinator(coordApi as any);
      assert.ok(tools.some((entry) => entry.name === "forge_boot"));
      console.log("PASS: result fixtures, configured TUI/print shell, refusal and resume guards");
      process.exit(0);
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

        PI_TEST_BIN=${realPi} PI_RELAY_MODULE=${../pkgs/pi-provider-relay/relay.py} PI_TASK_EXTENSION=${extDir}/task.ts PI_KAGI_BIN=${kagi}/bin/kagi \
          python3 ${../pkgs/pi-provider-relay/test_relay.py}
        mkdir -p results
        cp ${../pkgs/pi-session/results.py} results/results.py
        cp ${../pkgs/pi-session/test_results.py} results/test_results.py
        cp ${../pkgs/pi-session/result-fixtures.json} results/result-fixtures.json
        python3 results/test_results.py
        echo '{"shellPath":"${pkgs.bash}/bin/bash","shellCommandPrefix":"export SHELL_PREFIX_FIXTURE=1"}' > agent/settings.json
        PI_CODING_AGENT_DIR="$PWD/agent" ${realPi} --no-extensions --no-approve \
          -e ${runtimeProbe} --mode rpc > runtime-probe.log 2>&1
        grep -q 'PASS: result fixtures' runtime-probe.log || fail "runtime probe failed: $(cat runtime-probe.log)"

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
        echo "$c" | grep -q -- '- --allow-ssh-agent (test ssh-agent grant heading)' \
          || fail "carried run missing ssh-agent in the missing list"
        echo "$c" | grep -q -- '- --allow-kagi ' && fail "missing list includes a carried grant"
        stop_server

        start_server ""
        PI_COORD_ROLE=main PI_COORD_SOCKET="$PWD/synthetic-broker.sock" PI_COORD_TOKEN=synthetic \
          run_pi coord -e ${extDir}/coordinator.ts
        jq -e '.tools | any(.function.name == "spawn_agent")' captures/coord.jsonl >/dev/null \
          || fail "coordinator tool registration missing spawn_agent"
        jq -e '.tools | any(.function.name == "agent_answer")' captures/coord.jsonl >/dev/null \
          || fail "coordinator tool registration missing dialog answers"
        c=$(sysp coord)
        echo "$c" | grep -q 'Resume never replays interrupted work' \
          || fail "coordinator guidance missing resume policy"
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

        touch "$out"
  ''
