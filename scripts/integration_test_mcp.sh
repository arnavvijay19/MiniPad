#!/bin/sh
# End-to-end test of the Windows execution backend over a real HTTP socket.
#
# The user's actual Desktop Commander endpoint lives on their LAN and is not
# reachable from CI or a development container, so this runs the real Swift
# client, tool-binding adapter and executor against scripts/mock_desktop_commander.py:
# a genuine HTTP server speaking genuine MCP Streamable HTTP.
#
# What this verifies that the unit tests cannot:
#   * the handshake over a real socket, including Mcp-Session-Id round-tripping
#   * tool discovery and verb binding against a live tools/list
#   * argument mapping on real calls, with real effects on real files
#   * the SSE response path with a chunked body and a progress notification
#   * transparent re-handshake after the server drops the session (404)
#   * the shell-emulation fallback when the endpoint has no write_file
#
# What it cannot verify: that the remote OS is Windows. Commands run through the
# local shell. The compact-surface case therefore asserts on the PowerShell
# command the executor *emits*, not on its effect.
#
# Everything happens under a fresh temp directory, which is removed on exit.
#
# Usage: ./scripts/integration_test_mcp.sh [path-to-swift-bin-dir]

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${TMPDIR:-/tmp}/minipad-mcp-integration-$$"
[ $# -ge 1 ] && PATH="$1:$PATH"

PORT=${MCP_TEST_PORT:-18766}
SERVER_PID=""

cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

command -v swift >/dev/null 2>&1 || {
    echo "No swift toolchain on PATH. Pass one: $0 /path/to/swift/usr/bin" >&2
    exit 1
}

mkdir -p "$WORK/sandbox" "$WORK/driver/Sources/Driver"

# ---------------------------------------------------------------------------
# Assemble a driver package around the real production sources.
# ---------------------------------------------------------------------------
cat > "$WORK/driver/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Driver",
    targets: [.executableTarget(name: "Driver", path: "Sources/Driver")]
)
EOF

for f in \
    Agent/Unified/ExecutionTarget.swift \
    Agent/Unified/UnifiedPath.swift \
    Agent/Unified/RemoteEndpointConfig.swift \
    Agent/Unified/UnifiedToolRouting.swift \
    Agent/Unified/RemoteCommandRisk.swift \
    Agent/Unified/MCP/MCPWireProtocol.swift \
    Agent/Unified/MCP/HTTPStreamTransport.swift \
    Agent/Unified/MCP/MCPHTTPClient.swift \
    Agent/Unified/Windows/DesktopCommanderAdapter.swift \
    Agent/Unified/Windows/WindowsResultParser.swift \
    Agent/Unified/Windows/WindowsExecutor.swift
do
    ln -sf "$ROOT/src/ios/$f" "$WORK/driver/Sources/Driver/"
done

# A Linux HTTP transport. swift-corelibs-foundation has no
# URLSession.AsyncBytes, so URLSessionStreamTransport (the shipped Darwin one)
# can't compile here — but HTTPStreamTransport exists precisely so a different
# implementation can be dropped in. The bytes still cross a real socket.
cat > "$WORK/driver/Sources/Driver/LinuxTransport.swift" <<'EOF'
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LinuxStreamTransport: HTTPStreamTransport {
    func send(
        url: URL, method: String, headers: [String: String],
        body: Data, timeout: TimeInterval
    ) async throws -> HTTPStreamResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { c in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { c.resume(throwing: HTTPStreamError.network(error.localizedDescription)) }
                else if let data, let response { c.resume(returning: (data, response)) }
                else { c.resume(throwing: HTTPStreamError.network("empty response")) }
            }.resume()
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPStreamError.network("non-HTTP response")
        }
        var headerMap: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { headerMap[ks] = vs }
        }
        // Delivered as one chunk. The SSE parser is a fed-bytes state machine
        // and is fuzzed across every split point by the unit tests, so chunking
        // adds nothing here.
        let stream = AsyncThrowingStream<Data, Error> { c in
            if !data.isEmpty { c.yield(data) }
            c.finish()
        }
        return HTTPStreamResponse(status: http.statusCode, headers: headerMap, body: stream)
    }
}

struct NoSecrets: RemoteEndpointSecretStore {
    func bearerToken(endpointId: String) -> String? { nil }
    func environmentValue(_ name: String) -> String? { nil }
}
EOF

cp "$ROOT/scripts/integration_driver.swift" "$WORK/driver/Sources/Driver/main.swift"

# ---------------------------------------------------------------------------
# Run each scenario against a freshly-started server.
# ---------------------------------------------------------------------------
start_server() {   # surface, extra args...
    surface="$1"; shift
    rm -rf "$WORK/sandbox"; mkdir -p "$WORK/sandbox"
    python3 "$ROOT/scripts/mock_desktop_commander.py" \
        --port "$PORT" --root "$WORK/sandbox" --surface "$surface" "$@" \
        >"$WORK/server.log" 2>&1 &
    SERVER_PID=$!
    # Wait for the port rather than sleeping a fixed amount.
    i=0
    while [ $i -lt 100 ]; do
        if python3 -c "
import socket,sys
s=socket.socket()
s.settimeout(0.2)
sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT))==0 else 1)
" 2>/dev/null; then return 0; fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "server did not come up on port $PORT" >&2
    cat "$WORK/server.log" >&2
    exit 1
}

stop_server() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
    sleep 0.2
}

echo "Building the integration driver ..."
(cd "$WORK/driver" && swift build 2>&1 | grep -E "error:" || true)
DRIVER="$WORK/driver/.build/debug/Driver"
[ -x "$DRIVER" ] || { echo "driver failed to build" >&2; exit 1; }

status=0
run_scenario() {   # label, scenario-name, surface, extra server args...
    label="$1"; scenario="$2"; surface="$3"; shift 3
    printf '\n=== %s ===\n' "$label"
    start_server "$surface" "$@"
    if timeout 90 "$DRIVER" "$scenario" "http://127.0.0.1:$PORT/mcp" "$WORK/sandbox"; then
        :
    else
        status=1
    fi
    stop_server
}

run_scenario "Full surface — native tool binding"    full     full
run_scenario "Compact surface — shell emulation"     compact  compact
run_scenario "SSE responses"                         sse      full --sse
run_scenario "Session dropped mid-run (404)"         reconnect full --session-drop 5

printf '\n'
if [ "$status" -eq 0 ]; then
    echo "OK — every MCP integration scenario passed"
else
    echo "FAIL — see above" >&2
fi
exit "$status"
