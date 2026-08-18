#!/usr/bin/env bash
#
# linux_test_harness.sh — run the unified-agent unit tests without a Mac.
#
# The new code in this fork is written against Foundation alone, so it can be
# compiled and tested on Linux exactly as the Xcode `MinisTests` target does.
# This script is the permanent, repeatable form of the ad-hoc harness that was
# used during development; keeping it in the repository means CI runs the same
# thing a developer runs, and that the source manifest below cannot silently
# drift away from what the Xcode target compiles.
#
# The harness builds under **Swift 6 strict concurrency**, which is stricter
# than the app target's Swift 5 language mode, so passing here implies these
# files compile in the app target.
#
# Usage:
#   ./scripts/linux_test_harness.sh [/path/to/swift/usr/bin] [--keep]
#
# Exit status is `swift test`'s.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS="$REPO_ROOT/src/ios"

SWIFT_BIN="${1:-}"
if [ -n "$SWIFT_BIN" ] && [ "$SWIFT_BIN" != "--keep" ]; then
    export PATH="$SWIFT_BIN:$PATH"
    shift
fi
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

command -v swift >/dev/null || {
    echo "swift not on PATH. Pass the toolchain's bin directory as \$1." >&2
    exit 127
}

echo "== toolchain =="
swift --version

# ---------------------------------------------------------------------------
# Source manifest
#
# Production sources that the unified-agent tests exercise. These are the files
# that compile with Foundation alone. Anything needing UIKit/SwiftUI/MLX is
# deliberately absent — it is covered by the Xcode build, not by this harness.
#
# `URLSessionStreamTransport.swift` is excluded on purpose:
# `URLSession.AsyncBytes` does not exist in swift-corelibs-foundation. That is
# precisely why `HTTPStreamTransport` is a protocol — see ARCHITECTURE §2.3.
#
# MLXLocalProvider.swift is listed but only its MLX-free half compiles here:
# the runtime is behind `#if MINIS_LOCAL_INFERENCE`, which only the Xcode app
# target defines.
# ---------------------------------------------------------------------------
SOURCES=(
    Providers/AgentProvider.swift
    Providers/Local/LocalAgentProviderFactory.swift
    Providers/Local/LocalModelCatalog.swift
    Providers/Local/LocalToolCallSalvage.swift
    Providers/Local/LocalTranscriptDelta.swift
    Providers/Local/MLXLocalProvider.swift
    Agent/Unified/ExecutionTarget.swift
    Agent/Unified/UnifiedPath.swift
    Agent/Unified/RemoteEndpointConfig.swift
    Agent/Unified/RemoteCommandRisk.swift
    Agent/Unified/ToolSurfacePolicy.swift
    Agent/Unified/UnifiedToolRouting.swift
    Agent/Unified/MCP/MCPWireProtocol.swift
    Agent/Unified/MCP/HTTPStreamTransport.swift
    Agent/Unified/MCP/MCPHTTPClient.swift
    Agent/Unified/Windows/DesktopCommanderAdapter.swift
    Agent/Unified/Windows/WindowsResultParser.swift
    Agent/Unified/Windows/WindowsExecutor.swift
    Agent/Unified/Shortcuts/ShortcutsBridge.swift
)

# Test files from the Xcode MinisTests target that depend only on the sources
# above. Upstream tests are not listed: they need upstream sources that pull in
# UIKit, and the Xcode target is their gate.
TESTS=(
    TestSupport_AgentTypes.swift
    LocalModelTests.swift
    LocalTranscriptTests.swift
    MCPHTTPClientTests.swift
    MCPWireProtocolTests.swift
    RemoteCommandRiskTests.swift
    RemoteEndpointConfigTests.swift
    ShortcutsBridgeTests.swift
    ToolSurfacePolicyTests.swift
    UnifiedExecutionTests.swift
    UnifiedToolRoutingTests.swift
    WindowsExecutorTests.swift
)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/minis-harness.XXXXXX")"
if [ "$KEEP" -eq 0 ]; then
    trap 'rm -rf "$WORK"' EXIT
else
    echo "== keeping $WORK =="
fi

DEST="$WORK/Tests/UnifiedCoreTests"
mkdir -p "$DEST"

cat > "$WORK/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UnifiedCoreHarness",
    targets: [
        .testTarget(name: "UnifiedCoreTests", path: "Tests/UnifiedCoreTests")
    ]
)
EOF

missing=0
for f in "${SOURCES[@]}"; do
    src="$IOS/$f"
    if [ ! -f "$src" ]; then
        echo "MISSING production source: src/ios/$f" >&2
        missing=1
        continue
    fi
    # Flatten: SwiftPM compiles every file in the target directory, and two
    # sources never share a basename here.
    cp "$src" "$DEST/$(basename "$f")"
done
for f in "${TESTS[@]}"; do
    src="$IOS/MinisTests/$f"
    if [ ! -f "$src" ]; then
        echo "MISSING test source: src/ios/MinisTests/$f" >&2
        missing=1
        continue
    fi
    cp "$src" "$DEST/$f"
done
if [ "$missing" -ne 0 ]; then
    echo "Harness manifest is out of date — a listed file no longer exists." >&2
    exit 2
fi

echo "== $(ls "$DEST" | wc -l | tr -d ' ') files =="
cd "$WORK"
swift test 2>&1 | tee "$WORK/test.log"
status="${PIPESTATUS[0]}"

# `swift test` prints the summary line; surface it plainly for CI logs.
grep -E "Executed [0-9]+ tests" "$WORK/test.log" | tail -2 || true
exit "$status"
