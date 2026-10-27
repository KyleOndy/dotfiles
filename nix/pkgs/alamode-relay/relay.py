"""Parent-owned provider and tool relay. Never substitute request bodies."""

import copy
import hmac
import http.client
import ipaddress
import json
import math
import re
import secrets
import select
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


KAGI_BASE_URL = "https://kagi.com/api/v1"
LINEAR_URL = "https://api.linear.app/graphql"
TOOL_MAX_REQUEST_BYTES = 128 * 1024
# GraphQL names are [_A-Za-z][_0-9A-Za-z]* with no escape syntax, so a document
# without this token holds only queries. A string literal or comment that
# contains it is refused too, which costs a read nothing it needs.
LINEAR_WRITE = re.compile(r"(?<![_0-9A-Za-z])(?:mutation|subscription)(?![_0-9A-Za-z])")
# The only writes a linear grant carries, keyed by document with whitespace
# collapsed, each mapped to its variables: None for a string, else the input
# fields that variable may set. Matched whole, so a session cannot alias, batch
# or extend a mutation. extensions/linear.ts sends these same documents.
LINEAR_MUTATIONS = {
    "mutation Comment($input: CommentCreateInput!) { "
    "commentCreate(input: $input) { success comment { url } } }": {
        "input": {"issueId", "body"},
    },
    "mutation Update($id: String!, $input: IssueUpdateInput!) { "
    "issueUpdate(id: $id, input: $input) { success issue { identifier "
    "priorityLabel state { name } assignee { displayName } } } }": {
        "id": None,
        "input": {"stateId", "assigneeId", "priority"},
    },
}
# Seconds. A request inside this window after a ring is answered but silent,
# so an agent looping on the route cannot hold the host's speaker.
BELL_INTERVAL = 10

API_PATHS = {
    "openai-completions": "/chat/completions",
    "openai-responses": "/responses",
    "anthropic-messages": "/v1/messages",
}
MODEL_FIELDS = {
    "id",
    "name",
    "api",
    "reasoning",
    "input",
    "inputLimits",
    "cost",
    "contextWindow",
    "maxTokens",
    "thinkingLevelMap",
    "promptCache",
    "samplingParams",
    "samplingParamsByThinkingLevel",
    "compat",
}
HEADER_NAME = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
FORBIDDEN_HEADERS = {
    "host",
    "connection",
    "content-length",
    "transfer-encoding",
    "upgrade",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "content-encoding",
    "accept-encoding",
}


def _invalid_constant(_):
    raise ValueError("JSON numbers must be finite")


def _headers(values):
    result = {}
    for name, value in values.items():
        if (
            not isinstance(name, str)
            or not HEADER_NAME.fullmatch(name)
            or name.lower() in FORBIDDEN_HEADERS
            or not isinstance(value, str)
            or any(ord(c) < 32 or ord(c) > 126 for c in value)
        ):
            raise ValueError("Invalid trusted provider header")
        result[name.lower()] = value
    return result


def _endpoint(url, allow_private_hosts):
    if not isinstance(url, str) or any(ord(c) <= 32 for c in url):
        raise ValueError("Provider baseUrl must be an absolute HTTPS URL")
    parsed = urlsplit(url)
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("Provider baseUrl must have no userinfo, query or fragment")
    if parsed.scheme == "http" and parsed.hostname not in allow_private_hosts:
        raise ValueError("Plain HTTP provider requires explicit host approval")
    # Force validation of malformed and out-of-range ports before starting a server.
    _ = parsed.port
    return parsed


def _connect(host, port, timeout, allowed):
    addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    if not addresses:
        raise OSError("Provider DNS returned no addresses")
    if host not in allowed and any(
        not ipaddress.ip_address(item[4][0]).is_global for item in addresses
    ):
        raise OSError("Private provider address requires explicit host approval")
    last_error = None
    for family, kind, proto, _, address in addresses:
        sock = socket.socket(family, kind, proto)
        sock.settimeout(timeout)
        try:
            sock.connect(address)
            return sock
        except OSError as error:
            last_error = error
            sock.close()
    raise last_error


def _kagi_payload(payload, operation):
    if not isinstance(payload, dict):
        return False
    if operation == "search":
        return (
            set(payload) <= {"query", "limit"}
            and isinstance(payload.get("query"), str)
            and 0 < len(payload["query"]) <= 8192
            and type(payload.get("limit", 10)) is int
            and 1 <= payload.get("limit", 10) <= 100
        )
    if set(payload) != {"pages"} or not isinstance(payload["pages"], list):
        return False
    if not 1 <= len(payload["pages"]) <= 10:
        return False
    for page in payload["pages"]:
        if not isinstance(page, dict) or set(page) != {"url"}:
            return False
        url = page["url"]
        if not isinstance(url, str) or not 0 < len(url) <= 8192:
            return False
        try:
            parsed = urlsplit(url)
            if (
                parsed.scheme not in ("http", "https")
                or not parsed.hostname
                or parsed.username is not None
                or parsed.password is not None
                or any(ord(char) < 32 for char in url)
            ):
                return False
            _ = parsed.port
        except ValueError:
            return False
    return True


def _linear_payload(payload):
    if not isinstance(payload, dict) or not set(payload) <= {"query", "variables"}:
        return False
    query = payload.get("query")
    variables = payload.get("variables", {})
    if not isinstance(query, str) or not 0 < len(query) <= 16384:
        return False
    if not isinstance(variables, dict):
        return False
    if not LINEAR_WRITE.search(query):
        return True
    shape = LINEAR_MUTATIONS.get(" ".join(query.split()))
    if shape is None or set(variables) != set(shape):
        return False
    for name, fields in shape.items():
        value = variables[name]
        if fields is None:
            if not isinstance(value, str) or not value:
                return False
        elif not isinstance(value, dict) or not value or not set(value) <= fields:
            return False
    return True


def _inline_content(content):
    if content is None or isinstance(content, str):
        return True
    if not isinstance(content, list):
        return False
    for block in content:
        if not isinstance(block, dict):
            return False
        kind = block.get("type")
        if kind in ("image_url", "input_image"):
            image = block.get("image_url", "")
            url = image.get("url", "") if isinstance(image, dict) else image
            if (
                "file_id" in block
                or not isinstance(url, str)
                or not url.startswith("data:image/")
            ):
                return False
        elif kind in ("file", "input_file"):
            source = block.get("file", block)
            if (
                not isinstance(source, dict)
                or set(source) & {"file_id", "file_url"}
                or not isinstance(source.get("file_data"), str)
            ):
                return False
        elif kind in ("image", "document"):
            source = block.get("source", {})
            if (
                not isinstance(source, dict)
                or source.get("type") not in ("base64", "text", "content")
                or "file_id" in source
            ):
                return False
            if source["type"] == "content" and not _inline_content(
                source.get("content")
            ):
                return False
        elif kind == "tool_result":
            if not _inline_content(block.get("content")):
                return False
        elif kind not in (
            "text",
            "input_text",
            "output_text",
            "refusal",
            "thinking",
            "redacted_thinking",
            "tool_use",
            "input_audio",
        ):
            return False
    return True


def _stateless_inference(payload, api):
    # Inspect protocol envelopes only. Tool arguments, schemas and text are data.
    selectors = {
        "previous_response_id",
        "conversation",
        "prompt",
        "container",
        "mcp_servers",
        "data_sources",
        "thread_id",
        "assistant_id",
    }
    if set(payload) & selectors or (
        "store" in payload and payload["store"] is not False
    ):
        return False
    if api == "openai-responses":
        payload["store"] = False
        items = payload.get("input", [])
        if isinstance(items, str):
            return True
        if not isinstance(items, list):
            return False
        for item in items:
            if not isinstance(item, dict):
                return False
            kind = item.get("type", "message" if "role" in item else None)
            if kind == "message":
                if "content" not in item or not _inline_content(item["content"]):
                    return False
            elif kind in ("function_call_output", "custom_tool_call_output"):
                if not _inline_content(item.get("output")):
                    return False
            elif kind in ("function_call", "custom_tool_call"):
                if not isinstance(
                    item.get("arguments" if kind == "function_call" else "input"), str
                ):
                    return False
            elif kind == "reasoning":
                if "summary" not in item and "encrypted_content" not in item:
                    return False
                if "id" in item and (
                    not isinstance(item.get("encrypted_content"), str)
                    or not item["encrypted_content"]
                ):
                    return False
            elif kind in ("additional_tools", "tool_search_call", "tool_search_output"):
                if item.get("execution", "client") != "client":
                    return False
                tools = item.get("tools", [])
                if not isinstance(tools, list) or any(
                    not isinstance(tool, dict) or tool.get("type") != "function"
                    for tool in tools
                ):
                    return False
            else:
                return False
        return True
    messages = payload.get("messages", [])
    if not isinstance(messages, list):
        return False
    for message in messages:
        if not isinstance(message, dict) or not _inline_content(message.get("content")):
            return False
        if isinstance(message.get("audio"), dict) and "id" in message["audio"]:
            return False
    return api != "anthropic-messages" or _inline_content(payload.get("system"))


class _Server(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def process_request(self, request, address):
        if not self.relay.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.relay.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.relay.slots.release()

    def handle_error(self, request, address):
        pass


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        self.request.settimeout(self.server.relay.io_timeout)
        super().setup()

    def log_message(self, *_):
        pass

    def _error(self, code, message):
        data = json.dumps({"error": {"message": message}}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self.close_connection = True
        relay = self.server.relay
        route = relay.routes.get(self.path)
        authorization = self.headers.get_all("Authorization", [])
        api_keys = self.headers.get_all("x-api-key", [])
        supplied = authorization[0].removeprefix("Bearer ") if authorization else ""
        if not authorization and api_keys:
            supplied = api_keys[0]
        if (
            route is None
            or len(authorization) > 1
            or len(api_keys) > 1
            or (authorization and api_keys)
            or not hmac.compare_digest(supplied.encode(), relay.token.encode())
            or relay.closed.is_set()
            or time.monotonic() >= relay.expires_at
        ):
            self._error(403, "Provider capability denied or expired")
            return
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or self.headers.get(
            "Content-Encoding"
        ):
            self._error(400, "Encoded requests are not supported")
            return
        if len(lengths) != 1 or not re.fullmatch(r"[0-9]+", lengths[0]):
            self._error(411, "One Content-Length is required")
            return
        length = int(lengths[0])
        limit = (
            min(relay.max_request_bytes, TOOL_MAX_REQUEST_BYTES)
            if route["api"] in ("kagi", "linear")
            else relay.max_request_bytes
        )
        if not 0 < length <= limit:
            self._error(413, "Provider request is too large")
            return
        try:
            body = self.rfile.read(length)
            if len(body) != length:
                return
            payload = json.loads(body, parse_constant=_invalid_constant)
        except (ValueError, RecursionError):
            self._error(400, "Invalid JSON request")
            return
        if route["api"] == "bell":
            if payload != {}:
                self._error(400, "Invalid bell request")
                return
            now = time.monotonic()
            with relay.lock:
                ring = now - relay.rung_at >= BELL_INTERVAL
                if ring:
                    relay.rung_at = now
            if ring:
                relay.bell()
            self.send_response(204)
            self.end_headers()
            return
        if route["api"] == "kagi":
            if not _kagi_payload(payload, route["operation"]):
                self._error(400, "Invalid scoped Kagi request")
                return
        elif route["api"] == "linear":
            if not _linear_payload(payload):
                self._error(403, "Linear request is outside this capability")
                return
        else:
            if not isinstance(payload, dict) or payload.get("model") != route["model"]:
                self._error(403, "Model is outside this capability")
                return
            if payload.get("background") or payload.get("stream") is not True:
                self._error(400, "Only foreground streaming inference is supported")
                return
            if not _stateless_inference(payload, route["api"]):
                self._error(403, "Only inline stateless inference is supported")
                return
            for key in ("max_tokens", "max_completion_tokens", "max_output_tokens"):
                if key in payload and (
                    type(payload[key]) is not int
                    or not 0 < payload[key] <= route["max_tokens"]
                ):
                    self._error(403, "Output token limit exceeded")
                    return
            if not any(
                key in payload
                for key in ("max_tokens", "max_completion_tokens", "max_output_tokens")
            ):
                key = (
                    "max_output_tokens"
                    if route["api"] == "openai-responses"
                    else "max_tokens"
                )
                payload[key] = route["max_tokens"]
            # Server-side tools can fetch URLs or incur costs outside inference.
            tools = payload.get("tools", [])
            allowed_tool = (
                "custom" if route["api"] == "anthropic-messages" else "function"
            )
            if not isinstance(tools, list) or any(
                not isinstance(tool, dict)
                or tool.get("type", allowed_tool) != allowed_tool
                for tool in tools
            ):
                self._error(403, "Only client-executed tools are supported")
                return
        with relay.lock:
            if relay.requests >= relay.request_limit:
                self._error(429, "Session provider request budget exhausted")
                return
            relay.requests += 1
        try:
            body = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode()
        except (ValueError, RecursionError):
            self._error(400, "Invalid JSON request")
            return
        if len(body) > relay.max_request_bytes:
            self._error(413, "Provider request is too large")
            return
        endpoint = route["endpoint"]
        connection_type = (
            http.client.HTTPSConnection
            if endpoint.scheme == "https"
            else http.client.HTTPConnection
        )
        connection = connection_type(
            endpoint.hostname, endpoint.port, timeout=relay.io_timeout
        )
        connection.auto_open = 0
        # Connect to the validated address, while HTTPS retains hostname verification and SNI.
        connection._create_connection = lambda address, timeout, *_: _connect(
            address[0], address[1], timeout, relay.allow_private_hosts
        )
        started = False
        with relay.lock:
            relay.active[self.connection] = (
                connection,
                time.monotonic() + relay.request_timeout,
            )
        try:
            connection.connect()
            connection._relay_socket = connection.sock
            connection.request(
                "POST", route["upstream_path"], body=body, headers=route["headers"]
            )
            response = connection.getresponse()
            if 300 <= response.status < 400:
                self._error(502, "Provider redirects are refused")
                return
            self.send_response(response.status)
            self.send_header(
                "Content-Type",
                response.getheader("Content-Type", "application/octet-stream"),
            )
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            started = True
            count = 0
            while chunk := response.read1(65536):
                count += len(chunk)
                if count > relay.max_response_bytes or relay.closed.is_set():
                    return
                self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        except (OSError, ValueError, http.client.HTTPException):
            if not started:
                self._error(502, "Provider transport failed")
        finally:
            with relay.lock:
                relay.active.pop(self.connection, None)
            connection.close()


def provider_routes(
    catalog, credentials, *, allowed_models=None, allow_private_hosts=(), token=""
):
    """Relay routes for every permitted model, and the providers pi sees with
    each model's baseUrl as a relay path. Raises ValueError for anything the
    relay refuses, and opens nothing, so a deploy check runs it as is."""
    allow_private_hosts = frozenset(allow_private_hosts)
    routes, providers = {}, {}
    scope = None if allowed_models is None else frozenset(allowed_models)
    for provider, config in catalog.get("providers", {}).items():
        models = []
        for definition in config.get("models", []):
            model_id = definition["id"]
            identity = f"{provider}/{model_id}"
            if scope is not None and identity not in scope:
                continue
            model = {
                **definition,
                **config.get("modelOverrides", {}).get(model_id, {}),
                "id": model_id,
            }
            api = model.get("api", config.get("api"))
            if api not in API_PATHS or model.get("type", "chat") != "chat":
                raise ValueError("Provider API is not supported by the inference relay")
            auth = credentials.get(identity, credentials.get(provider, {}))
            endpoint = _endpoint(
                auth.get("baseUrl", model.get("baseUrl", config.get("baseUrl"))),
                allow_private_hosts,
            )
            headers = {
                "content-type": "application/json",
                "accept": "text/event-stream",
            }
            if api == "anthropic-messages":
                headers["anthropic-version"] = "2023-06-01"
            key = auth.get("apiKey")
            if key:
                headers[
                    "x-api-key" if api == "anthropic-messages" else "authorization"
                ] = key if api == "anthropic-messages" else f"Bearer {key}"
            headers.update(_headers(auth.get("headers", {})))
            headers.update(_headers(auth.get("modelHeaders", {}).get(model_id, {})))
            headers = _headers(headers)
            max_tokens = model.get("maxTokens", 16384)
            if type(max_tokens) is not int or max_tokens <= 0:
                raise ValueError("Model maxTokens must be a positive integer")
            prefix = f"/model/{len(models)}-{len(routes)}"
            path = prefix + API_PATHS[api]
            route = {
                "api": api,
                "model": model_id,
                "endpoint": endpoint,
                "upstream_path": endpoint.path.rstrip("/") + API_PATHS[api],
                "headers": headers,
                "max_tokens": max_tokens,
            }
            routes[path] = route
            if api == "anthropic-messages":
                routes[path + "?beta=true"] = route
            clean = {
                key: copy.deepcopy(value)
                for key, value in model.items()
                if key in MODEL_FIELDS
            }
            clean.update(api=api, baseUrl=prefix)
            clean["compat"] = {
                **config.get("compat", {}),
                **model.get("compat", {}),
            }
            models.append(clean)
        if models:
            providers[provider] = {"apiKey": token, "models": models}
    return routes, providers


class Relay:
    def __init__(
        self,
        catalog,
        credentials,
        *,
        allowed_models=None,
        tool_credentials=None,
        bell=None,
        allow_private_hosts=(),
        request_limit=1000,
        max_concurrency=8,
        lifetime=86400,
        max_request_bytes=16 * 1024 * 1024,
        max_response_bytes=64 * 1024 * 1024,
        io_timeout=120,
        request_timeout=1800,
    ):
        if any(
            type(value) is not int or value <= 0
            for value in (
                request_limit,
                max_concurrency,
                max_request_bytes,
                max_response_bytes,
            )
        ) or any(
            type(value) not in (int, float) or not math.isfinite(value) or value <= 0
            for value in (lifetime, io_timeout, request_timeout)
        ):
            raise ValueError("Relay limits must be positive and finite")
        self.token = secrets.token_urlsafe(32)
        self.allow_private_hosts = frozenset(allow_private_hosts)
        self.request_limit = request_limit
        self.max_request_bytes = max_request_bytes
        self.max_response_bytes = max_response_bytes
        self.io_timeout = io_timeout
        self.request_timeout = request_timeout
        self.expires_at = time.monotonic() + lifetime
        self.requests = 0
        self.lock = threading.Lock()
        self.slots = threading.BoundedSemaphore(max_concurrency)
        self.closed = threading.Event()
        self.active = {}
        self.tool_env = {}
        self.routes, providers = provider_routes(
            catalog,
            credentials,
            allowed_models=allowed_models,
            allow_private_hosts=self.allow_private_hosts,
            token=self.token,
        )
        self.catalog = {"providers": providers}
        tool_credentials = tool_credentials or {}
        if set(tool_credentials) - {"kagi", "linear"}:
            raise ValueError("Unsupported relay tool capability")
        if "kagi" in tool_credentials:
            key = tool_credentials["kagi"]
            if not isinstance(key, str) or not key:
                raise ValueError("Kagi requires a nonempty resolved credential")
            endpoint = _endpoint(KAGI_BASE_URL, self.allow_private_hosts)
            headers = _headers(
                {
                    "content-type": "application/json",
                    "accept": "application/json",
                    "authorization": "Bearer " + key,
                }
            )
            for operation in ("search", "extract"):
                self.routes["/tool/kagi/" + operation] = {
                    "api": "kagi",
                    "operation": operation,
                    "endpoint": endpoint,
                    "upstream_path": endpoint.path.rstrip("/") + "/" + operation,
                    "headers": headers,
                }
        if "linear" in tool_credentials:
            key = tool_credentials["linear"]
            if not isinstance(key, str) or not key:
                raise ValueError("Linear requires a nonempty resolved credential")
            endpoint = _endpoint(LINEAR_URL, self.allow_private_hosts)
            self.routes["/tool/linear"] = {
                "api": "linear",
                "endpoint": endpoint,
                "upstream_path": endpoint.path,
                # A personal API key goes in Authorization bare, without Bearer.
                "headers": _headers(
                    {
                        "content-type": "application/json",
                        "accept": "application/json",
                        "authorization": key,
                    }
                ),
            }
        if not self.routes:
            raise ValueError("No permitted provider models")
        # bell plays the host's notification sound, which the sandbox cannot
        # reach. It takes no arguments and must not block the handler.
        self.bell = bell
        self.rung_at = -math.inf
        if bell is not None:
            self.routes["/tool/bell"] = {"api": "bell"}
        self.server = _Server(("127.0.0.1", 0), _Handler)
        self.server.relay = self
        self.port = self.server.server_port
        if "kagi" in tool_credentials:
            self.tool_env.update(
                KAGI_API_KEY=self.token,
                KAGI_API_URL=f"http://127.0.0.1:{self.port}/tool/kagi",
            )
        if "linear" in tool_credentials:
            self.tool_env.update(
                ALAMODE_LINEAR_TOKEN=self.token,
                ALAMODE_LINEAR_URL=f"http://127.0.0.1:{self.port}/tool/linear",
            )
        if bell is not None:
            self.tool_env.update(
                ALAMODE_BELL_TOKEN=self.token,
                ALAMODE_BELL_URL=f"http://127.0.0.1:{self.port}/tool/bell",
            )
        for config in self.catalog["providers"].values():
            for model in config["models"]:
                model["baseUrl"] = f"http://127.0.0.1:{self.port}" + model["baseUrl"]
        self.thread = threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True
        )
        self.thread.start()
        self.monitor = threading.Thread(target=self._monitor, daemon=True)
        self.monitor.start()

    def _monitor(self):
        while not self.closed.wait(0.1):
            now = time.monotonic()
            with self.lock:
                active = list(self.active.items())
            for client, (connection, deadline) in active:
                try:
                    disconnected = bool(select.select([client], [], [], 0)[0])
                    if disconnected or now >= deadline or now >= self.expires_at:
                        self._cancel(client, connection)
                except (OSError, ValueError):
                    pass

    @staticmethod
    def _cancel(client, connection):
        for sock in (
            client,
            connection.sock,
            getattr(connection, "_relay_socket", None),
        ):
            if sock is not None:
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        connection.close()

    def close(self):
        if self.closed.is_set():
            return
        self.closed.set()
        with self.lock:
            active = list(self.active.items())
        for client, (connection, _) in active:
            self._cancel(client, connection)
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=1)
        self.monitor.join(timeout=1)
        self.routes.clear()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def start_relay(catalog, credentials, **limits):
    return Relay(catalog, credentials, **limits)
