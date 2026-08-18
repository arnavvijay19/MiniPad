#!/usr/bin/env python3
"""Probe a Desktop Commander MCP endpoint, from anywhere that has Python.

Why this exists
---------------
When the Windows target does not work on the iPad, there are two very
different causes and they look identical from inside the app: the endpoint is
unreachable from the iPad's network, or the app's client is wrong. This
separates them. Run it from a-Shell or Termius on the iPad itself and it
answers the first question on its own — same device, same Wi-Fi, no app
involved.

It speaks the same MCP Streamable HTTP protocol the app does (revision
2025-06-18): initialize, notifications/initialized, tools/list. It reads only.
`--call-echo` optionally runs one harmless command to prove execution works
end to end; nothing else writes anything.

Usage:
    python3 scripts/probe_desktop_commander.py http://192.168.1.38:8766/mcp
    python3 scripts/probe_desktop_commander.py <url> --token <bearer>
    python3 scripts/probe_desktop_commander.py <url> --call-echo

The endpoint is an argument, never a default: it is user configuration, and no
address belongs in this repository.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

PROTOCOL = "2025-06-18"

# The five the app binds directly. Without one of these, that capability is
# emulated over the shell — which works, but a file write becomes a base64
# round-trip through PowerShell rather than a single call.
REQUIRED = ["start_process", "interact_with_process", "read_process_output",
            "read_file", "apply_patch"]

# Present on a fuller server. Each one the endpoint has is one fewer emulation.
OPTIONAL = ["write_file", "force_terminate", "list_directory"]


class Session:
    def __init__(self, url: str, token: str | None, timeout: float) -> None:
        self.url = url
        self.timeout = timeout
        self.session_id: str | None = None
        self.headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if token:
            self.headers["Authorization"] = f"Bearer {token}"
        self._next_id = 0

    def send(self, method: str, params: dict | None = None, notify: bool = False):
        body: dict = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        if not notify:
            self._next_id += 1
            body["id"] = self._next_id

        headers = dict(self.headers)
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id

        request = urllib.request.Request(
            self.url, data=json.dumps(body).encode(), headers=headers, method="POST")
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            sid = response.headers.get("Mcp-Session-Id")
            if sid:
                self.session_id = sid
            raw = response.read().decode("utf-8", "replace")
            content_type = response.headers.get("Content-Type", "")

        if notify:
            return None
        if "text/event-stream" in content_type:
            # Server-sent events: take the data: line of the first event that
            # carries our id.
            for line in raw.splitlines():
                if line.startswith("data:"):
                    payload = json.loads(line[5:].strip())
                    if payload.get("id") == body["id"]:
                        return payload
            raise RuntimeError(f"no SSE event matched id {body['id']}")
        return json.loads(raw)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("url", help="e.g. http://192.168.1.10:8766/mcp")
    parser.add_argument("--token", help="bearer token, if the endpoint needs one")
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--call-echo", action="store_true",
                        help="also run one harmless command to prove execution works")
    args = parser.parse_args()

    session = Session(args.url, args.token, args.timeout)

    print(f"-> {args.url}")
    try:
        result = session.send("initialize", {
            "protocolVersion": PROTOCOL,
            "capabilities": {},
            "clientInfo": {"name": "minipad-probe", "version": "1.0"},
        })
    except urllib.error.HTTPError as exc:
        print(f"   HTTP {exc.code} {exc.reason}", file=sys.stderr)
        if exc.code in (401, 403):
            print("   The endpoint wants credentials — pass --token.", file=sys.stderr)
        return 1
    except urllib.error.URLError as exc:
        print(f"   unreachable: {exc.reason}", file=sys.stderr)
        print("   From the iPad this usually means: wrong address, the PC is "
              "asleep, the server is not listening on the LAN interface (only "
              "on 127.0.0.1), or a firewall rule.", file=sys.stderr)
        return 1

    if "error" in result:
        print(f"   initialize failed: {result['error']}", file=sys.stderr)
        return 1

    info = result.get("result", {})
    server = info.get("serverInfo", {})
    print(f"   {server.get('name', '?')} {server.get('version', '?')}"
          f"   protocol {info.get('protocolVersion', '?')}")
    print(f"   session  {session.session_id or '(none — stateless server)'}")

    session.send("notifications/initialized", {}, notify=True)

    listed = session.send("tools/list", {})
    tools = listed.get("result", {}).get("tools", [])
    names = sorted(tool["name"] for tool in tools)
    print(f"\n   {len(names)} tools:")
    for name in names:
        print(f"     {name}")

    missing = [verb for verb in REQUIRED if verb not in names]
    extra = [verb for verb in OPTIONAL if verb in names]
    print()
    print(f"   core verbs   {len(REQUIRED) - len(missing)}/{len(REQUIRED)} bound natively"
          + (f" — missing {', '.join(missing)}" if missing else ""))
    print(f"   optional     {len(extra)}/{len(OPTIONAL)} present"
          + (f" ({', '.join(extra)})" if extra else ""))
    if missing:
        print("\n   The app emulates the missing core verbs over the shell. That "
              "works, but it is slower and less exact.")
    if "write_file" not in names:
        print("   No write_file: file writes go through a base64 round-trip in "
              "PowerShell. Correct for binary and CRLF content, just slower.")

    if args.call_echo:
        print("\n   running one harmless command")
        shell = next((n for n in ("start_process", "execute_command", "run_command")
                      if n in names), None)
        if not shell:
            print("   no command verb to call", file=sys.stderr)
            return 1
        called = session.send("tools/call", {
            "name": shell,
            "arguments": {"command": "hostname", "timeout_ms": 10000},
        })
        if "error" in called:
            print(f"   call failed: {called['error']}", file=sys.stderr)
            return 1
        content = called.get("result", {}).get("content", [])
        text = "".join(part.get("text", "") for part in content if isinstance(part, dict))
        fallback = ("(no output — the server may need a follow-up "
                    "read_process_output call, which the app does)")
        print("   " + (text.strip()[:400] or fallback))

    print("\nOK  the endpoint is reachable and speaks MCP from this machine.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
