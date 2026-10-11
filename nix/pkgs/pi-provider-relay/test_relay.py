import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch


MODULE = Path(os.environ.get("PI_RELAY_MODULE", Path(__file__).with_name("relay.py")))
spec = importlib.util.spec_from_file_location("relay", MODULE)
relay_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay_module)
start_relay = relay_module.start_relay
KEY = "synthetic-backing-key"


class Upstream(BaseHTTPRequestHandler):
    def do_POST(self):
        data = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.loads(data)
        self.server.calls.append((self.path, dict(self.headers), body))
        if "FORCE_PROVIDER_FAILURE" in json.dumps(body):
            self.send_response(403)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"fixture-provider-failure"}}')
            return
        if body.get("test_case") == "redirect":
            self.send_response(302)
            self.send_header("Location", "/credentials")
            self.end_headers()
            return
        if self.path.startswith("/kagi/"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            data = (
                {
                    "search": [
                        {
                            "title": "Fixture",
                            "url": "https://example.invalid",
                            "snippet": "Search fixture",
                        }
                    ]
                }
                if self.path.endswith("/search")
                else [
                    {"url": page["url"], "markdown": "Page fixture"}
                    for page in body["pages"]
                ]
            )
            self.wfile.write(json.dumps({"data": data}).encode())
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
            if body.get("test_case") == "disconnect":
                for _ in range(1000):
                    self.wfile.write(b"data: fixture\n\n")
                    self.wfile.flush()
                    time.sleep(0.01)
                return
            if body.get("test_case") == "delayed":
                self.wfile.write(b"data: first\n\n")
                self.wfile.flush()
                self.server.release.wait(5)
                self.wfile.write(b"data: last\n\n")
                return
            family = self.path.split("/")[1]
            previous = sum(path == self.path for path, _, _ in self.server.calls)
            for event, value in stream_events(family, tool_call=previous == 1):
                raw = value if isinstance(value, str) else json.dumps(value)
                payload = (
                    "" if event == "data" else f"event: {event}\n"
                ) + f"data: {raw}\n\n"
                self.wfile.write(payload.encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            self.server.disconnected.set()

    def log_message(self, *_):
        pass


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        self.upstream.daemon_threads = True
        self.upstream.calls = []
        self.upstream.disconnected = threading.Event()
        self.upstream.release = threading.Event()
        threading.Thread(target=self.upstream.serve_forever, daemon=True).start()
        self.catalog = {"providers": {}}
        self.credentials = {}
        for api in relay_module.API_PATHS:
            self.catalog["providers"][api] = {
                "api": api,
                "baseUrl": f"http://127.0.0.1:{self.upstream.server_port}/{api}",
                "apiKey": "!trusted-resolver-never-in-child",
                "headers": {"X-Private": KEY},
                "models": [{"id": "fixture", "name": "Fixture", "maxTokens": 1024}],
            }
            self.credentials[api] = {
                "apiKey": KEY,
                "headers": {"X-Provider-Policy": "fixed"},
            }
        self.relay = start_relay(
            self.catalog, self.credentials, allow_private_hosts=["127.0.0.1"]
        )
        self.path = self.route("openai-completions")

    def tearDown(self):
        self.upstream.release.set()
        self.relay.close()
        self.upstream.shutdown()
        self.upstream.server_close()

    def route(self, api):
        return next(
            path for path, route in self.relay.routes.items() if route["api"] == api
        )

    def request(self, path=None, token=None, headers=None, **payload):
        connection = http.client.HTTPConnection("127.0.0.1", self.relay.port, timeout=5)
        data = json.dumps({"model": "fixture", "stream": True, **payload})
        connection.request(
            "POST",
            path or self.path,
            body=data,
            headers={
                "Authorization": "Bearer "
                + (self.relay.token if token is None else token),
                "Content-Type": "application/json",
                **(headers or {}),
            },
        )
        response = connection.getresponse()
        status, body = response.status, response.read()
        connection.close()
        return status, body

    def test_scope_and_header_isolation(self):
        for args in (
            {"token": "wrong"},
            {"path": "/admin"},
            {"model": "other"},
            {"path": self.path + "?target=elsewhere"},
        ):
            self.assertEqual(self.request(**args)[0], 403)
        self.assertFalse(self.upstream.calls)
        self.assertEqual(
            self.request(
                headers={
                    "Host": "unapproved.invalid",
                    "X-Upstream-URL": "http://unapproved.invalid",
                    "X-Provider-Policy": "evil",
                },
                messages=[{"role": "user", "content": self.relay.token}],
            )[0],
            200,
        )
        path, headers, payload = self.upstream.calls[-1]
        self.assertEqual(path, "/openai-completions/chat/completions")
        headers = {k.lower(): v for k, v in headers.items()}
        self.assertEqual(headers["authorization"], "Bearer " + KEY)
        self.assertEqual(headers["x-provider-policy"], "fixed")
        self.assertNotIn("x-upstream-url", headers)
        self.assertEqual(payload["messages"][0]["content"], self.relay.token)
        sanitized = json.dumps(self.relay.catalog)
        self.assertNotIn(KEY, sanitized)
        self.assertNotIn("trusted-resolver", sanitized)

    def test_limits_redirect_and_expiry(self):
        self.assertEqual(self.request(max_tokens=1025)[0], 403)
        self.assertEqual(self.request(tools=[{"type": "web_search"}])[0], 403)
        self.assertEqual(self.request(background=True)[0], 400)
        self.assertEqual(self.request(stream=False)[0], 400)
        self.assertEqual(self.request(test_case="redirect")[0], 502)
        self.assertEqual(len(self.upstream.calls), 1)
        self.relay.max_request_bytes = 100
        self.assertEqual(self.request(messages=["x" * 200])[0], 413)
        self.relay.max_request_bytes = 16384
        self.relay.request_limit = self.relay.requests
        self.assertEqual(self.request()[0], 429)
        self.relay.expires_at = time.monotonic() - 1
        self.assertEqual(self.request()[0], 403)

    def test_stored_state_references_never_reach_upstream(self):
        for api in self.catalog["providers"]:
            for field, value in (
                ("previous_response_id", "resp_other_session"),
                ("conversation", {"id": "conv_other_session"}),
                ("prompt", {"id": "pmpt_account_template"}),
                ("container", "container_other_session"),
                ("mcp_servers", [{"url": "https://example.invalid"}]),
                ("data_sources", [{"type": "azure_search"}]),
                ("thread_id", "thread_other_session"),
                ("assistant_id", "asst_other_session"),
                ("store", True),
                ("store", "false"),
            ):
                with self.subTest(api=api, field=field, value=value):
                    self.assertEqual(
                        self.request(path=self.route(api), **{field: value})[0], 403
                    )
                    self.assertFalse(self.upstream.calls)

        for item in (
            {"type": "item_reference", "id": "msg_other_session"},
            {"id": "msg_other_session"},
            {"type": "reasoning", "id": "rs_other_session", "summary": []},
            {
                "type": "reasoning",
                "id": "rs_other_session",
                "summary": [],
                "encrypted_content": "",
            },
            {"type": "tool_search_output", "execution": "server", "tools": []},
            {"type": "additional_tools", "tools": [{"type": "file_search"}]},
            {
                "type": "function_call_output",
                "call_id": "call_fixture",
                "output": [{"type": "input_file", "file_id": "file_account"}],
            },
        ):
            with self.subTest(item=item):
                self.assertEqual(
                    self.request(path=self.route("openai-responses"), input=[item])[0],
                    403,
                )
                self.assertFalse(self.upstream.calls)

        for api, block in (
            ("openai-responses", {"type": "input_file", "file_id": "file_account"}),
            ("openai-responses", {"type": "input_image", "file_id": "file_account"}),
            (
                "openai-responses",
                {"type": "input_image", "image_url": "https://example.invalid/i.png"},
            ),
            (
                "openai-completions",
                {"type": "file", "file": {"file_id": "file_account"}},
            ),
            (
                "anthropic-messages",
                {
                    "type": "document",
                    "source": {"type": "file", "file_id": "file_account"},
                },
            ),
            (
                "anthropic-messages",
                {"type": "container_upload", "file_id": "file_account"},
            ),
            (
                "anthropic-messages",
                {
                    "type": "tool_result",
                    "tool_use_id": "call_fixture",
                    "content": [
                        {
                            "type": "image",
                            "source": {"type": "file", "file_id": "file_account"},
                        }
                    ],
                },
            ),
        ):
            with self.subTest(api=api, block=block):
                field = "input" if api == "openai-responses" else "messages"
                self.assertEqual(
                    self.request(
                        path=self.route(api),
                        **{field: [{"role": "user", "content": [block]}]},
                    )[0],
                    403,
                )
                self.assertFalse(self.upstream.calls)
        self.assertEqual(
            self.request(
                messages=[{"role": "assistant", "audio": {"id": "audio_account"}}]
            )[0],
            403,
        )
        self.assertFalse(self.upstream.calls)

    def test_inline_history_and_opaque_tool_data_are_preserved(self):
        arguments = {"previous_response_id": "literal data", "file_id": "literal data"}
        schema = {
            "type": "object",
            "properties": {name: {"type": "string"} for name in arguments},
        }
        image = "data:image/png;base64,aW1hZ2U="
        for api in self.catalog["providers"]:
            if api == "openai-responses":
                payload = {
                    "input": [
                        {
                            "role": "user",
                            "content": [{"type": "input_image", "image_url": image}],
                        },
                        {
                            "type": "reasoning",
                            "id": "rs_fixture",
                            "summary": [],
                            "encrypted_content": "synthetic-inline-reasoning",
                        },
                        {
                            "type": "function_call",
                            "id": "fc_fixture",
                            "call_id": "call_fixture",
                            "name": "fixture",
                            "arguments": json.dumps(arguments),
                        },
                        {
                            "type": "function_call_output",
                            "call_id": "call_fixture",
                            "output": json.dumps(arguments),
                        },
                    ],
                    "tools": [
                        {"type": "function", "name": "fixture", "parameters": schema}
                    ],
                }
            elif api == "openai-completions":
                payload = {
                    "messages": [
                        {
                            "role": "user",
                            "content": [
                                {"type": "text", "text": json.dumps(arguments)},
                                {"type": "image_url", "image_url": {"url": image}},
                            ],
                        }
                    ],
                    "tools": [
                        {
                            "type": "function",
                            "function": {"name": "fixture", "parameters": schema},
                        }
                    ],
                }
            else:
                payload = {
                    "messages": [
                        {
                            "role": "assistant",
                            "content": [
                                {
                                    "type": "tool_use",
                                    "id": "call_fixture",
                                    "name": "fixture",
                                    "input": arguments,
                                }
                            ],
                        }
                    ],
                    "tools": [{"name": "fixture", "input_schema": schema}],
                }
            with self.subTest(api=api):
                self.assertEqual(self.request(path=self.route(api), **payload)[0], 200)
                forwarded = self.upstream.calls[-1][2]
                for field, value in payload.items():
                    self.assertEqual(forwarded[field], value)
                if api == "openai-responses":
                    self.assertIs(forwarded["store"], False)

    def test_scoped_kagi_routes(self):
        self.assertEqual(self.request(path="/tool/kagi/search")[0], 403)
        with (
            patch.object(
                relay_module,
                "KAGI_BASE_URL",
                f"http://127.0.0.1:{self.upstream.server_port}/kagi",
            ),
            start_relay(
                self.catalog,
                self.credentials,
                tool_credentials={"kagi": KEY},
                allow_private_hosts=["127.0.0.1"],
            ) as relay,
        ):
            self.assertNotIn(KEY, json.dumps(relay.tool_env))
            self.assertEqual(relay.tool_env["KAGI_API_KEY"], relay.token)

            def send(path, payload, token=None):
                connection = http.client.HTTPConnection(
                    "127.0.0.1", relay.port, timeout=2
                )
                connection.request(
                    "POST",
                    path,
                    json.dumps(payload),
                    {
                        "Authorization": "Bearer " + (token or relay.token),
                        "X-Upstream-URL": "https://elsewhere.invalid/",
                    },
                )
                response = connection.getresponse()
                result = response.status, response.read()
                connection.close()
                return result

            path = "/tool/kagi/search"
            self.assertEqual(send(path, {"query": "fixture", "limit": 10})[0], 200)
            target, headers, body = self.upstream.calls[-1]
            self.assertEqual(target, "/kagi/search")
            self.assertEqual(headers["authorization"], "Bearer " + KEY)
            self.assertNotIn("X-Upstream-URL", headers)
            self.assertEqual(body, {"query": "fixture", "limit": 10})
            self.assertEqual(
                send(
                    "/tool/kagi/extract",
                    {"pages": [{"url": "https://example.invalid/a"}]},
                )[0],
                200,
            )
            count = len(self.upstream.calls)
            for request_path, payload, status in (
                (path, {"query": "x", "url": "https://elsewhere.invalid"}, 400),
                (path, {"query": "x" * 8193}, 400),
                (path, {"query": "x", "limit": -1}, 400),
                (path, {"query": "x" * (128 * 1024)}, 413),
                (
                    "/tool/kagi/extract",
                    {"pages": [{"url": "https://example.invalid"}] * 11},
                    400,
                ),
                ("/tool/kagi/extract", {"pages": [{"url": "file:///etc/passwd"}]}, 400),
                (path + "?target=elsewhere", {"query": "x"}, 403),
                ("/tool/kagi/admin", {}, 403),
            ):
                with self.subTest(path=request_path, status=status):
                    self.assertEqual(send(request_path, payload)[0], status)
            self.assertEqual(send(path, {"query": "x"}, "wrong")[0], 403)
            self.assertEqual(len(self.upstream.calls), count)
            kagi = os.environ.get("PI_KAGI_BIN")
            if kagi:
                environment = {"PATH": os.environ["PATH"], **relay.tool_env}
                for args, expected in (
                    (["search", "fixture"], "Search fixture"),
                    (["read", "https://example.invalid"], "Page fixture"),
                ):
                    result = subprocess.run(
                        [kagi, *args],
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(expected, result.stdout)
                    self.assertNotIn(KEY, result.stdout + result.stderr)

    def test_streams_before_upstream_finishes_and_disconnects(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.relay.port, timeout=2)
        connection.request(
            "POST",
            self.path,
            json.dumps({"model": "fixture", "stream": True, "test_case": "delayed"}),
            {"Authorization": "Bearer " + self.relay.token},
        )
        response = connection.getresponse()
        self.assertEqual(response.read1(1024), b"data: first\n\n")
        self.upstream.release.set()
        self.assertEqual(response.read(), b"data: last\n\n")
        connection.close()
        connection = http.client.HTTPConnection("127.0.0.1", self.relay.port, timeout=2)
        connection.request(
            "POST",
            self.path,
            json.dumps({"model": "fixture", "stream": True, "test_case": "disconnect"}),
            {"Authorization": "Bearer " + self.relay.token},
        )
        response = connection.getresponse()
        self.assertTrue(response.read1(64))
        response.close()
        connection.close()
        self.assertTrue(
            self.upstream.disconnected.wait(2),
            "Client disconnect did not cancel upstream",
        )

    def test_model_override_and_invalid_trusted_config(self):
        self.catalog["providers"]["openai-completions"]["modelOverrides"] = {
            "fixture": {
                "baseUrl": f"http://127.0.0.1:{self.upstream.server_port}/override",
                "headers": {"x-hidden": KEY},
            }
        }
        self.credentials["openai-completions"]["modelHeaders"] = {
            "fixture": {"X-Model": "fixed-model"}
        }
        with start_relay(
            self.catalog,
            self.credentials,
            allowed_models=["openai-completions/fixture"],
            allow_private_hosts=["127.0.0.1"],
        ) as relay:
            self.assertEqual(len(relay.routes), 1)
            route = next(iter(relay.routes.values()))
            self.assertEqual(route["upstream_path"], "/override/chat/completions")
            self.assertEqual(route["headers"]["x-model"], "fixed-model")
            self.assertNotIn(KEY, json.dumps(relay.catalog))
        with self.assertRaises(ValueError):
            start_relay(self.catalog, self.credentials)
        self.credentials["openai-completions"]["headers"] = {"Host": "wrong"}
        with self.assertRaises(ValueError):
            start_relay(
                self.catalog, self.credentials, allow_private_hosts=["127.0.0.1"]
            )
        with patch.object(
            relay_module.socket,
            "getaddrinfo",
            return_value=[
                (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 443))
            ],
        ):
            with self.assertRaises(OSError):
                relay_module._connect("public.invalid", 443, 1, set())

    def test_response_limit_revocation_and_tls_failure(self):
        self.relay.max_response_bytes = 8
        with self.assertRaises(http.client.IncompleteRead):
            self.request()
        self.relay.max_response_bytes = 65536
        self.catalog["providers"]["openai-completions"]["baseUrl"] = (
            f"https://127.0.0.1:{self.upstream.server_port}/openai-completions"
        )
        with start_relay(
            self.catalog,
            self.credentials,
            allowed_models=["openai-completions/fixture"],
            allow_private_hosts=["127.0.0.1"],
            io_timeout=1,
        ) as relay:
            connection = http.client.HTTPConnection("127.0.0.1", relay.port, timeout=3)
            connection.request(
                "POST",
                next(iter(relay.routes)),
                json.dumps({"model": "fixture", "stream": True}),
                {"Authorization": "Bearer " + relay.token},
            )
            self.assertEqual(connection.getresponse().status, 502)
            connection.close()
        calls = len(self.upstream.calls)
        self.relay.close()
        with self.assertRaises(OSError):
            self.request()
        self.assertEqual(len(self.upstream.calls), calls)

    @unittest.skipUnless(
        os.environ.get("PI_TEST_BIN"), "PI_TEST_BIN is required for real Pi integration"
    )
    def test_real_pi_task_marks_provider_failure_despite_zero_exit(self):
        extension = os.environ.get(
            "PI_TASK_EXTENSION",
            str(
                Path(__file__).parents[2]
                / "modules/hm_modules/dev/pi/extensions/task.ts"
            ),
        )
        with tempfile.TemporaryDirectory(prefix="pi-task-result-test-") as temporary:
            root = Path(temporary)
            agent = root / "agent"
            agent.mkdir()
            logs = root / "logs"
            logs.mkdir()
            (agent / "models.json").write_text(json.dumps(self.relay.catalog))
            (agent / "auth.json").write_text("{}")
            (agent / "settings.json").write_text(
                json.dumps({"retry": {"enabled": False}})
            )
            probe = root / "probe.ts"
            probe.write_text(
                "import task from "
                + json.dumps(extension)
                + ";\n"
                + "export default async function () {\n"
                + "  let tool; task({registerTool: t => tool = t});\n"
                + '  const result = await tool.execute("fixture", {tasks:["FORCE_PROVIDER_FAILURE"]}, undefined, undefined, {mode:"print", hasUI:false, model:{provider:"openai-completions",id:"fixture"}});\n'
                + "  console.log(JSON.stringify(result));\n"
                + '  process.exit(result.details.results[0].state === "failed" ? 0 : 1);\n'
                + "}\n"
            )
            result = subprocess.run(
                [
                    os.environ["PI_TEST_BIN"],
                    "--no-extensions",
                    "--no-approve",
                    "-e",
                    str(probe),
                    "--mode",
                    "rpc",
                ],
                cwd=root,
                env={
                    "HOME": temporary,
                    "PI_CODING_AGENT_DIR": str(agent),
                    "PI_REAL_BIN": os.environ["PI_TEST_BIN"],
                    "PI_TASK_LOG_DIR": str(logs),
                    "PATH": os.environ["PATH"],
                },
                text=True,
                capture_output=True,
                timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("fixture-provider-failure", result.stdout)
            events = [
                json.loads(line)
                for file in logs.glob("*.jsonl")
                for line in file.read_text().splitlines()
            ]
            outcome = next(event["outcome"] for event in events if "outcome" in event)
            self.assertEqual(outcome["code"], 0)
            self.assertEqual(outcome["result"], "error")

    @unittest.skipUnless(
        os.environ.get("PI_TEST_BIN"), "PI_TEST_BIN is required for real Pi integration"
    )
    def test_real_pi_tool_roundtrip_all_api_families(self):
        with tempfile.TemporaryDirectory(prefix="pi-relay-test-") as temporary:
            root = Path(temporary)
            agent = root / "agent"
            agent.mkdir()
            (agent / "models.json").write_text(json.dumps(self.relay.catalog))
            (agent / "auth.json").write_text("{}")
            (agent / "settings.json").write_text(
                json.dumps({"retry": {"enabled": False}})
            )
            for api in self.catalog["providers"]:
                result = subprocess.run(
                    [
                        os.environ["PI_TEST_BIN"],
                        "--no-extensions",
                        "--no-approve",
                        "--model",
                        api + "/fixture",
                        "--mode",
                        "json",
                        "--no-session",
                        "Fixture request",
                    ],
                    cwd=root,
                    env={
                        "HOME": temporary,
                        "PI_CODING_AGENT_DIR": str(agent),
                        "PATH": os.environ["PATH"],
                    },
                    text=True,
                    capture_output=True,
                    timeout=20,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                events = [
                    json.loads(line)
                    for line in result.stdout.splitlines()
                    if line.startswith("{")
                ]
                final = next(
                    event["message"]
                    for event in reversed(events)
                    if event.get("type") == "message_end"
                    and event.get("message", {}).get("role") == "assistant"
                )
                self.assertEqual(final["stopReason"], "stop", (api, final))
                self.assertIn("fixture relay reply", json.dumps(final))
                self.assertEqual(
                    sum(event.get("type") == "tool_execution_end" for event in events),
                    1,
                )
                self.assertTrue(
                    any(
                        "tool-fixture" in json.dumps(body)
                        for path, _, body in self.upstream.calls
                        if path.startswith("/" + api)
                    )
                )
                if api == "openai-responses":
                    bodies = [
                        body
                        for path, _, body in self.upstream.calls
                        if path.startswith("/" + api)
                    ]
                    self.assertEqual(len(bodies), 2)
                    self.assertTrue(all(body["store"] is False for body in bodies))
                    replay = next(
                        item
                        for item in bodies[-1]["input"]
                        if item.get("type") == "reasoning"
                    )
                    self.assertEqual(replay["id"], "rs_fixture")
                    self.assertEqual(replay["summary"], [])
                    self.assertEqual(
                        replay["encrypted_content"], "synthetic-inline-reasoning"
                    )


def stream_events(family, tool_call=False):
    if tool_call:
        args = json.dumps({"command": "printf 'tool-fixture'"})
        if family == "openai-completions":
            head = {
                "id": "chat-tool-fixture",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": "fixture",
                "choices": [
                    {
                        "index": 0,
                        "delta": {
                            "role": "assistant",
                            "tool_calls": [
                                {
                                    "index": 0,
                                    "id": "call_fixture",
                                    "type": "function",
                                    "function": {"name": "bash", "arguments": args},
                                }
                            ],
                        },
                        "finish_reason": None,
                    }
                ],
            }
            return [
                ("data", head),
                (
                    "data",
                    {
                        **head,
                        "choices": [
                            {"index": 0, "delta": {}, "finish_reason": "tool_calls"}
                        ],
                    },
                ),
                ("data", "[DONE]"),
            ]
        if family == "openai-responses":
            reasoning = {"id": "rs_fixture", "type": "reasoning", "summary": []}
            item = {
                "id": "fc_fixture",
                "type": "function_call",
                "call_id": "call_fixture",
                "name": "bash",
                "arguments": args,
                "status": "completed",
            }
            response = {
                "id": "resp_fixture_tool",
                "object": "response",
                "created_at": 0,
                "model": "fixture",
                "status": "completed",
                "output": [
                    {**reasoning, "encrypted_content": "synthetic-inline-reasoning"},
                    item,
                ],
                "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
            }
            return [
                (
                    "response.created",
                    {
                        "type": "response.created",
                        "response": {**response, "status": "in_progress", "output": []},
                    },
                ),
                (
                    "response.output_item.added",
                    {
                        "type": "response.output_item.added",
                        "output_index": 0,
                        "item": reasoning,
                    },
                ),
                (
                    "response.output_item.done",
                    {
                        "type": "response.output_item.done",
                        "output_index": 0,
                        "item": reasoning,
                    },
                ),
                (
                    "response.output_item.added",
                    {
                        "type": "response.output_item.added",
                        "output_index": 1,
                        "item": {**item, "status": "in_progress", "arguments": ""},
                    },
                ),
                (
                    "response.function_call_arguments.delta",
                    {
                        "type": "response.function_call_arguments.delta",
                        "item_id": "fc_fixture",
                        "output_index": 1,
                        "delta": args,
                    },
                ),
                (
                    "response.output_item.done",
                    {
                        "type": "response.output_item.done",
                        "output_index": 1,
                        "item": item,
                    },
                ),
                (
                    "response.completed",
                    {"type": "response.completed", "response": response},
                ),
            ]
        return [
            (
                "message_start",
                {
                    "type": "message_start",
                    "message": {
                        "id": "msg_tool_fixture",
                        "type": "message",
                        "role": "assistant",
                        "model": "fixture",
                        "content": [],
                        "stop_reason": None,
                        "stop_sequence": None,
                        "usage": {"input_tokens": 1, "output_tokens": 0},
                    },
                },
            ),
            (
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {
                        "type": "tool_use",
                        "id": "call_fixture",
                        "name": "bash",
                        "input": {},
                    },
                },
            ),
            (
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "input_json_delta", "partial_json": args},
                },
            ),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            (
                "message_delta",
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": "tool_use", "stop_sequence": None},
                    "usage": {"output_tokens": 1},
                },
            ),
            ("message_stop", {"type": "message_stop"}),
        ]

    if family == "openai-completions":
        head = {
            "id": "chat-fixture",
            "object": "chat.completion.chunk",
            "created": 0,
            "model": "fixture",
            "choices": [
                {
                    "index": 0,
                    "delta": {"role": "assistant", "content": "fixture relay reply"},
                    "finish_reason": None,
                }
            ],
        }
        end = {
            **head,
            "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }
        return [("data", head), ("data", end), ("data", "[DONE]")]
    if family == "openai-responses":
        output = [
            {
                "id": "msg_fixture",
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [
                    {
                        "type": "output_text",
                        "text": "fixture relay reply",
                        "annotations": [],
                    }
                ],
            }
        ]
        response = {
            "id": "resp_fixture",
            "object": "response",
            "created_at": 0,
            "model": "fixture",
            "status": "completed",
            "output": output,
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
        }
        return [
            (
                "response.created",
                {
                    "type": "response.created",
                    "response": {**response, "status": "in_progress", "output": []},
                },
            ),
            (
                "response.output_item.added",
                {
                    "type": "response.output_item.added",
                    "output_index": 0,
                    "item": {**output[0], "status": "in_progress", "content": []},
                },
            ),
            (
                "response.output_text.delta",
                {
                    "type": "response.output_text.delta",
                    "item_id": "msg_fixture",
                    "output_index": 0,
                    "content_index": 0,
                    "delta": "fixture relay reply",
                },
            ),
            (
                "response.output_item.done",
                {
                    "type": "response.output_item.done",
                    "output_index": 0,
                    "item": output[0],
                },
            ),
            (
                "response.completed",
                {"type": "response.completed", "response": response},
            ),
        ]
    return [
        (
            "message_start",
            {
                "type": "message_start",
                "message": {
                    "id": "msg_fixture",
                    "type": "message",
                    "role": "assistant",
                    "model": "fixture",
                    "content": [],
                    "stop_reason": None,
                    "stop_sequence": None,
                    "usage": {"input_tokens": 1, "output_tokens": 0},
                },
            },
        ),
        (
            "content_block_start",
            {
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "text", "text": ""},
            },
        ),
        (
            "content_block_delta",
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": "fixture relay reply"},
            },
        ),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        (
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                "usage": {"output_tokens": 1},
            },
        ),
        ("message_stop", {"type": "message_stop"}),
    ]


if __name__ == "__main__":
    unittest.main()
