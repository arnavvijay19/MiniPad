#!/usr/bin/env python3
"""A conformant compact Desktop Commander MCP server, for integration tests.

The real endpoint lives on the user's LAN and is not reachable from CI or from
a development container. This stands in for it: a genuine HTTP server speaking
genuine MCP Streamable HTTP, so the Swift client, the tool-binding adapter and
the executor are exercised over a real socket rather than against a scripted
transport.

It is NOT a Windows machine. Commands run through the local shell, and paths
are POSIX. That is deliberate and it is the point of `--surface compact`:
with no `write_file` tool advertised, the executor must fall back to its
PowerShell emulation, and the test asserts on the command it *emits* rather
than on the effect of running it. What can be verified here is the wire
protocol, the tool binding, the argument mapping and the fallback decisions —
which is everything except the remote OS itself.

Safety: every file operation is confined to --root, which the runner points at
a fresh temporary directory. A path outside it is refused.

Usage:
    mock_desktop_commander.py --port 8766 --root /tmp/dc --surface compact|full
                              [--sse] [--session-drop N]
"""
import argparse
import http.server
import json
import os
import socketserver
import subprocess
import sys
import threading
import uuid

ARGS = None
SESSIONS = set()
PROCESSES = {}          # pid -> {"proc":…, "buffer":…, "done":bool}
REQUEST_COUNT = {"n": 0}
LOCK = threading.Lock()

PROTOCOL_VERSION = "2025-06-18"


# --------------------------------------------------------------------------
# Tool surfaces
# --------------------------------------------------------------------------

def _schema(props, required):
    return {
        "type": "object",
        "properties": {k: {"type": v} for k, v in props.items()},
        "required": required,
    }


COMPACT_TOOLS = [
    {"name": "start_process", "description": "Run a command",
     "inputSchema": _schema({"command": "string", "timeout_ms": "number",
                             "cwd": "string"}, ["command"])},
    {"name": "read_process_output", "description": "Read output from a process",
     "inputSchema": _schema({"pid": "string", "timeout_ms": "number"}, ["pid"])},
    {"name": "interact_with_process", "description": "Write to a process",
     "inputSchema": _schema({"pid": "string", "input": "string",
                             "timeout_ms": "number"}, ["pid", "input"])},
    {"name": "read_file", "description": "Read a file",
     "inputSchema": _schema({"path": "string", "offset": "number",
                             "length": "number"}, ["path"])},
    {"name": "apply_patch", "description": "Replace a string in a file",
     "inputSchema": _schema({"path": "string", "old_string": "string",
                             "new_string": "string", "replace_all": "boolean"},
                            ["path", "old_string", "new_string"])},
]

FULL_TOOLS = COMPACT_TOOLS + [
    {"name": "write_file", "description": "Write a file",
     "inputSchema": _schema({"path": "string", "content": "string"},
                            ["path", "content"])},
    {"name": "force_terminate", "description": "Kill a process",
     "inputSchema": _schema({"pid": "string"}, ["pid"])},
    {"name": "list_directory", "description": "List a directory",
     "inputSchema": _schema({"path": "string"}, ["path"])},
]


def tools():
    return FULL_TOOLS if ARGS.surface == "full" else COMPACT_TOOLS


# --------------------------------------------------------------------------
# Tool implementations
# --------------------------------------------------------------------------

def safe_path(path):
    """Confine every file operation to --root."""
    root = os.path.realpath(ARGS.root)
    candidate = os.path.realpath(os.path.join(root, path.lstrip("/\\")))
    if candidate != root and not candidate.startswith(root + os.sep):
        raise ValueError("path escapes the sandbox root")
    return candidate


def call_tool(name, args):
    """Returns (content_text, is_error, structured)."""
    if name == "start_process":
        command = args.get("command", "")
        cwd = args.get("cwd") or ARGS.root
        proc = subprocess.Popen(
            command, shell=True, cwd=cwd,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            stdin=subprocess.PIPE, text=True,
        )
        pid = str(proc.pid)
        with LOCK:
            PROCESSES[pid] = {"proc": proc, "buffer": "", "done": False}
        try:
            out, _ = proc.communicate(timeout=args.get("timeout_ms", 30000) / 1000.0)
            with LOCK:
                PROCESSES[pid]["buffer"] = out or ""
                PROCESSES[pid]["done"] = True
            return (f"Process started with PID {pid}\nProcess exited with code "
                    f"{proc.returncode}\n{out or ''}",
                    False, {"pid": int(pid), "exitCode": proc.returncode,
                            "isRunning": False})
        except subprocess.TimeoutExpired:
            return (f"Process started with PID {pid}, still running",
                    False, {"pid": int(pid), "isRunning": True})

    if name == "read_process_output":
        pid = str(args.get("pid", ""))
        with LOCK:
            entry = PROCESSES.get(pid)
        if entry is None:
            return (f"no such process: {pid}", True, None)
        if entry["done"]:
            return (entry["buffer"], False,
                    {"isRunning": False, "exitCode": entry["proc"].returncode})
        return ("", False, {"isRunning": True})

    if name == "interact_with_process":
        pid = str(args.get("pid", ""))
        with LOCK:
            entry = PROCESSES.get(pid)
        if entry is None:
            return (f"no such process: {pid}", True, None)
        try:
            entry["proc"].stdin.write(args.get("input", "") + "\n")
            entry["proc"].stdin.flush()
        except Exception as exc:                       # noqa: BLE001
            return (str(exc), True, None)
        return ("input sent", False, {"isRunning": True})

    if name == "force_terminate":
        pid = str(args.get("pid", ""))
        with LOCK:
            entry = PROCESSES.get(pid)
        if entry:
            entry["proc"].kill()
        return ("terminated", False, None)

    if name == "read_file":
        try:
            # newline="" disables universal-newline translation, so CRLF
            # content round-trips byte for byte.
            with open(safe_path(args["path"]), encoding="utf-8", newline="") as handle:
                return (handle.read(), False, None)
        except Exception as exc:                       # noqa: BLE001
            return (str(exc), True, None)

    if name == "write_file":
        try:
            target = safe_path(args["path"])
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w", encoding="utf-8", newline="") as handle:
                handle.write(args.get("content", ""))
            return (f"wrote {len(args.get('content', ''))} characters", False, None)
        except Exception as exc:                       # noqa: BLE001
            return (str(exc), True, None)

    if name == "apply_patch":
        try:
            target = safe_path(args["path"])
            with open(target, encoding="utf-8", newline="") as handle:
                text = handle.read()
            old = args["old_string"]
            count = text.count(old)
            if count == 0:
                return ("old_string not found", True, None)
            if count > 1 and not args.get("replace_all"):
                return (f"old_string matched {count} times", True, None)
            text = (text.replace(old, args["new_string"])
                    if args.get("replace_all")
                    else text.replace(old, args["new_string"], 1))
            with open(target, "w", encoding="utf-8", newline="") as handle:
                handle.write(text)
            return (f"replaced {count}", False, None)
        except Exception as exc:                       # noqa: BLE001
            return (str(exc), True, None)

    if name == "list_directory":
        try:
            return ("\n".join(sorted(os.listdir(safe_path(args["path"])))), False, None)
        except Exception as exc:                       # noqa: BLE001
            return (str(exc), True, None)

    return (f"unknown tool: {name}", True, None)


# --------------------------------------------------------------------------
# JSON-RPC / MCP
# --------------------------------------------------------------------------

def handle_rpc(message, session_id):
    method = message.get("method")
    rpc_id = message.get("id")

    if method == "initialize":
        return {"jsonrpc": "2.0", "id": rpc_id, "result": {
            "protocolVersion": PROTOCOL_VERSION,
            "serverInfo": {"name": "mock-desktop-commander", "version": "1.0.0"},
            "capabilities": {"tools": {}},
        }}

    if method == "notifications/initialized":
        return None                                     # 202, no body

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rpc_id, "result": {"tools": tools()}}

    if method == "tools/call":
        params = message.get("params") or {}
        text, is_error, structured = call_tool(
            params.get("name", ""), params.get("arguments") or {})
        result = {"content": [{"type": "text", "text": text}], "isError": is_error}
        if structured:
            result["structuredContent"] = structured
        return {"jsonrpc": "2.0", "id": rpc_id, "result": result}

    if method == "notifications/cancelled":
        return None

    return {"jsonrpc": "2.0", "id": rpc_id,
            "error": {"code": -32601, "message": f"method not found: {method}"}}


class Handler(http.server.BaseHTTPRequestHandler):

    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):                     # quiet
        if os.environ.get("MOCK_DC_VERBOSE"):
            sys.stderr.write("[mock-dc] " + fmt % a + "\n")

    def do_POST(self):                                  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            self.send_error(400, "bad json")
            return

        session_id = self.headers.get("Mcp-Session-Id")
        method = message.get("method")

        # Simulate a server restart: after N requests, reject the established
        # session with 404 so the client's re-handshake path is exercised.
        with LOCK:
            REQUEST_COUNT["n"] += 1
            count = REQUEST_COUNT["n"]
        if (ARGS.session_drop and count == ARGS.session_drop
                and method not in ("initialize", "notifications/initialized")):
            SESSIONS.discard(session_id)
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if method != "initialize" and session_id and session_id not in SESSIONS:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        response = handle_rpc(message, session_id)

        headers = {}
        if method == "initialize":
            new_session = uuid.uuid4().hex
            SESSIONS.add(new_session)
            headers["Mcp-Session-Id"] = new_session

        if response is None:
            self.send_response(202)
            for key, value in headers.items():
                self.send_header(key, value)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        # tools/call answers over SSE when --sse, so the streaming path and the
        # correlation-id matching get exercised against a real chunked body.
        use_sse = ARGS.sse and method == "tools/call"
        if use_sse:
            body = (
                "event: message\n"
                "data: " + json.dumps({
                    "jsonrpc": "2.0", "method": "notifications/progress",
                    "params": {"message": "working"}}) + "\n\n"
                "event: message\n"
                "data: " + json.dumps(response) + "\n\n"
            ).encode()
            content_type = "text/event-stream"
        else:
            body = json.dumps(response).encode()
            content_type = "application/json"

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    global ARGS
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--root", required=True)
    parser.add_argument("--surface", choices=["compact", "full"], default="compact")
    parser.add_argument("--sse", action="store_true")
    parser.add_argument("--session-drop", type=int, default=0,
                        help="reject the session on the Nth request, to test re-handshake")
    ARGS = parser.parse_args()
    os.makedirs(ARGS.root, exist_ok=True)

    with Server(("127.0.0.1", ARGS.port), Handler) as httpd:
        sys.stderr.write(f"[mock-dc] {ARGS.surface} surface on 127.0.0.1:{ARGS.port}, "
                         f"root={ARGS.root}\n")
        sys.stderr.flush()
        httpd.serve_forever()


if __name__ == "__main__":
    main()
