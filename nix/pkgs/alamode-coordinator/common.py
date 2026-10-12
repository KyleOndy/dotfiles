import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import socketserver
import sqlite3
import threading
import time

LIMIT = 2 * 1024 * 1024


class OutcomeUnknown(RuntimeError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def atomic_json(path, value):
    path = Path(path)
    temp = path.with_suffix(".tmp")
    with temp.open("w") as stream:
        json.dump(value, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def socket_directory():
    root = Path(os.environ.get("TMPDIR", "/tmp")) / f"alamode-{os.getuid()}"
    # Unix sockets on Darwin allow only 104 bytes, including the terminator.
    if len(str(root)) > 55:
        root = Path("/tmp") / f"alamode-{os.getuid()}"
    return root.parent.resolve() / root.name


def socket_path(path):
    root = socket_directory()
    root.mkdir(mode=0o700, exist_ok=True)
    if (
        root.is_symlink()
        or root.stat().st_uid != os.getuid()
        or root.stat().st_mode & 0o077
    ):
        raise ValueError("Socket directory must be private and owned by this user")
    return str(root / (hashlib.sha256(str(path).encode()).hexdigest()[:24] + ".sock"))


def lock_file(path):
    stream = open(path, "a+")
    try:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        stream.close()
        return None
    return stream


def request(address, token, body, timeout=30):
    wire = (canonical({**body, "token": token}) + "\n").encode()
    if len(wire) > LIMIT:
        raise ValueError("Request exceeds 2 MiB")
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(timeout)
        client.connect(address)
        client.sendall(wire)
        with client.makefile("rb") as stream:
            reply = stream.readline(LIMIT + 1)
        if not reply.endswith(b"\n") or len(reply) > LIMIT:
            raise ValueError("Invalid broker response")
        result = json.loads(reply)
        if not result.get("ok"):
            raise ValueError(result.get("error", "Broker request failed"))
        return result["data"]


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, address, dispatch):
        self.dispatch = dispatch
        self.capacity = threading.BoundedSemaphore(32)
        Path(address).unlink(missing_ok=True)
        super().__init__(address, Handler)
        os.chmod(address, 0o600)

    def process_request(self, connection, address):
        if not self.capacity.acquire(blocking=False):
            connection.close()
            return
        try:
            super().process_request(connection, address)
        except Exception:
            self.capacity.release()
            raise

    def process_request_thread(self, connection, address):
        try:
            super().process_request_thread(connection, address)
        finally:
            self.capacity.release()


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(30)
        try:
            line = self.rfile.readline(LIMIT + 1)
            if len(line) > LIMIT or not line.endswith(b"\n"):
                raise ValueError("Request exceeds 2 MiB or has no newline")
            body = json.loads(line)
            if not isinstance(body, dict):
                raise ValueError("Request must be an object")
            reply = {"ok": True, "data": self.server.dispatch(body)}
        except Exception as error:
            reply = {"ok": False, "error": str(error)}
        wire = (canonical(reply) + "\n").encode()
        if len(wire) > LIMIT:
            wire = b'{"ok":false,"error":"Response exceeds 2 MiB"}\n'
        try:
            self.wfile.write(wire)
        except (BrokenPipeError, ConnectionResetError):
            pass


class Store:
    def __init__(self, path):
        self.lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS state (name TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS operations (
                id TEXT PRIMARY KEY, payload TEXT NOT NULL, result TEXT
            );
            CREATE TABLE IF NOT EXISTS events (
                seq INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL
            );
        """)

    def get(self, name, default=None):
        with self.lock:
            row = self.db.execute(
                "SELECT value FROM state WHERE name=?", (name,)
            ).fetchone()
            return json.loads(row[0]) if row else default

    def put(self, name, value):
        with self.lock, self.db:
            self.db.execute(
                "INSERT OR REPLACE INTO state VALUES (?,?)", (name, canonical(value))
            )

    def states(self):
        with self.lock:
            return {
                key: json.loads(value)
                for key, value in self.db.execute("SELECT name,value FROM state")
            }

    def event(self, value):
        with self.lock, self.db:
            cursor = self.db.execute(
                "INSERT INTO events(value) VALUES (?)", (canonical(value),)
            )
            seq = cursor.lastrowid
            self.db.execute("DELETE FROM events WHERE seq < ?", (seq - 10000,))
            return seq

    def events(self, after):
        with self.lock:
            first = self.db.execute("SELECT min(seq) FROM events").fetchone()[0]
            rows = self.db.execute(
                "SELECT seq,value FROM events WHERE seq>? ORDER BY seq LIMIT 100",
                (after,),
            )
            return {
                "gap": bool(first and after and after < first - 1),
                "events": [
                    {"seq": seq, "event": json.loads(value)} for seq, value in rows
                ],
            }

    def operation(self, body, execute):
        identifier = body.get("id")
        if not isinstance(identifier, str) or not 1 <= len(identifier) <= 128:
            raise ValueError("Mutations require an operation id (1-128 characters)")
        payload = canonical(
            {key: value for key, value in body.items() if key != "token"}
        )
        with self.lock, self.db:
            row = self.db.execute(
                "SELECT payload,result FROM operations WHERE id=?", (identifier,)
            ).fetchone()
            if row:
                if row[0] != payload:
                    raise ValueError(
                        "Operation id was already used with different arguments"
                    )
                if row[1] is None:
                    return {
                        "operation": identifier,
                        "receipt": "uncertain",
                        "message": "Accepted before interruption; inspect status before explicit resume. The operation was not replayed.",
                    }
                return json.loads(row[1])
            self.db.execute(
                "INSERT INTO operations VALUES (?,?,NULL)", (identifier, payload)
            )
        try:
            result = execute()
        except OutcomeUnknown as error:
            result = {
                "operation": identifier,
                "receipt": "uncertain",
                "error": str(error),
            }
        except Exception as error:
            result = {"operation": identifier, "receipt": "failed", "error": str(error)}
        with self.lock, self.db:
            self.db.execute(
                "UPDATE operations SET result=? WHERE id=?",
                (canonical(result), identifier),
            )
        return result


class Pool:
    def __init__(self, root, kind, limit):
        self.root = Path(root)
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.kind = kind
        self.limit = limit
        self.lease = None

    def acquire(self):
        if self.lease:
            return
        for number in range(self.limit):
            lease = lock_file(self.root / f"{self.kind}-{number}.lock")
            if lease:
                self.lease = lease
                return
        raise ValueError(
            f"No {self.kind} capacity ({self.limit} slots); interrupt or close an agent first"
        )

    def release(self):
        if self.lease:
            self.lease.close()
            self.lease = None


def wait_socket(address, token, process=None):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            return request(address, token, {"op": "status"}, timeout=1)
        except (OSError, ValueError):
            if process and process.poll() is not None:
                raise ValueError("Service exited during startup; inspect its log")
            time.sleep(0.05)
    raise ValueError("Service startup timed out; inspect its log")
